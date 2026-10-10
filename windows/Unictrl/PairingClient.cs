using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace Unictrl;

/// The PC side of 6-digit pairing (docs/PROTOCOL.md): P-256 key agreement, both sides prove they know
/// the code with an HMAC over both public keys, and the pairing key comes from the shared secret.
internal static class PairingClient
{
    public enum Outcome { Paired, NotPairing, WrongCode, Unreachable }
    public sealed record Result(Outcome Outcome, string? PairingKey = null, string? MacId = null);

    /// The PC opens with MagicV2, its public key and its device ID; the Mac answers with Magic.
    private static readonly byte[] Magic = "UNICTRP1"u8.ToArray();
    private static readonly byte[] MagicV2 = "UNICTRP2"u8.ToArray();
    private static readonly byte[] NotPairingMagic = "UNICTRP0"u8.ToArray();

    public static Result Pair(string address, int port, string code, byte[] deviceId)
    {
        try
        {
            using var client = new TcpClient { NoDelay = true };
            if (!client.ConnectAsync(address, port).Wait(3000)) return new(Outcome.Unreachable);
            var stream = client.GetStream();
            stream.ReadTimeout = 5000;
            using var ecdh = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
            var q = ecdh.ExportParameters(false).Q;
            byte[] clientKey = [.. q.X!, .. q.Y!];
            stream.Write([.. MagicV2, .. clientKey, .. deviceId]);

            var magic = new byte[8];
            stream.ReadExactly(magic);
            if (magic.SequenceEqual(NotPairingMagic)) return new(Outcome.NotPairing);
            if (!magic.SequenceEqual(Magic)) return new(Outcome.Unreachable);
            var reply = new byte[64 + 16];
            stream.ReadExactly(reply);
            var serverKey = reply[..64];
            var macId = FormatUuid(reply.AsSpan(64, 16));

            using var server = ECDiffieHellman.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = serverKey[..32], Y = serverKey[32..] },
            });
            var shared = ecdh.DeriveRawSecretAgreement(server.PublicKey);
            stream.Write(Proof(code, "client", clientKey, serverKey));

            var serverProof = new byte[32];
            stream.ReadExactly(serverProof);
            if (!CryptographicOperations.FixedTimeEquals(serverProof, Proof(code, "server", clientKey, serverKey)))
                return new(Outcome.WrongCode);
            byte[] salt = [.. clientKey, .. serverKey];
            var key = HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, salt, "unictrl pairing key v1"u8.ToArray());
            return new(Outcome.Paired, Convert.ToBase64String(key), macId);
        }
        catch (Exception ex) when (ex is SocketException or IOException or AggregateException)
        {
            return new(Outcome.Unreachable);
        }
    }

    private static byte[] Proof(string code, string role, byte[] clientKey, byte[] serverKey)
    {
        byte[] message = [.. Encoding.UTF8.GetBytes($"unictrl pair {role}"), .. clientKey, .. serverKey];
        return HMACSHA256.HashData(Encoding.UTF8.GetBytes(code), message);
    }

    /// Same text as Swift's UUID.uuidString for the raw big-endian bytes.
    private static string FormatUuid(ReadOnlySpan<byte> b)
    {
        var hex = Convert.ToHexString(b);
        return $"{hex[..8]}-{hex[8..12]}-{hex[12..16]}-{hex[16..20]}-{hex[20..]}";
    }
}
