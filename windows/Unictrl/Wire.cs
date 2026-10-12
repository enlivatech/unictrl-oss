using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace Unictrl;

/// Message types; mirrors macos/Sources/Unictrl/Wire.swift and docs/PROTOCOL.md.
internal enum MessageType : byte
{
    Hello = 0x01,
    Screen = 0x02,
    Arrangement = 0x03,
    ArrangementEdit = 0x04,
    Reclaim = 0x05,
    Hosts = 0x06,
    Rename = 0x07,
    Enter = 0x10,
    Leave = 0x11,
    Move = 0x12,
    MoveRaw = 0x16,
    Button = 0x13,
    Wheel = 0x14,
    Key = 0x15,
    Action = 0x17,
    Ping = 0x20,
    Pong = 0x21,
    Stats = 0x22,
    Quality = 0x23,
}

/// AES-256-GCM framing: u16 big-endian length, ciphertext, 16-byte tag. Per-direction HKDF keys
/// and counter nonces, so replayed or reordered frames fail authentication.
internal sealed class SecureChannel : IDisposable
{
    /// The Mac answers with Magic; the PC opens with MagicV2 followed by its salt and device ID.
    public static readonly byte[] Magic = "UNICTRL1"u8.ToArray();
    public static readonly byte[] MagicV2 = "UNICTRL2"u8.ToArray();
    /// The Mac's answer when it does not know this PC (it was removed there).
    public static readonly byte[] NotPaired = "UNICTRL0"u8.ToArray();
    public const int SaltLength = 32;
    /// Quality reports with the full checklist need more than the early 4096.
    public const int MaxFrame = 16_384;

    private readonly AesGcm sendKey;
    private readonly AesGcm receiveKey;
    private ulong sendCounter;
    private ulong receiveCounter;

    public SecureChannel(string pairingKey, byte[] clientSalt, byte[] serverSalt, bool isServer)
    {
        var ikm = Encoding.UTF8.GetBytes(pairingKey);
        var salt = clientSalt.Concat(serverSalt).ToArray();
        byte[] Derive(string label) =>
            HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, 32, salt, Encoding.UTF8.GetBytes(label));
        var c2s = Derive("unictrl v1 client->server");
        var s2c = Derive("unictrl v1 server->client");
        sendKey = new AesGcm(isServer ? s2c : c2s, 16);
        receiveKey = new AesGcm(isServer ? c2s : s2c, 16);
    }

    private static byte[] Nonce(ulong counter)
    {
        var nonce = new byte[12];
        BinaryPrimitives.WriteUInt64BigEndian(nonce.AsSpan(4), counter);
        return nonce;
    }

    public byte[] Seal(ReadOnlySpan<byte> plaintext)
    {
        var bodyLength = plaintext.Length + 16;
        var frame = new byte[2 + bodyLength];
        BinaryPrimitives.WriteUInt16BigEndian(frame, (ushort)bodyLength);
        sendKey.Encrypt(Nonce(sendCounter++), plaintext, frame.AsSpan(2, plaintext.Length),
            frame.AsSpan(2 + plaintext.Length, 16));
        return frame;
    }

    /// Throws CryptographicException when the pairing key differs or the frame was tampered with.
    public byte[] Open(ReadOnlySpan<byte> body)
    {
        var plaintext = new byte[body.Length - 16];
        receiveKey.Decrypt(Nonce(receiveCounter), body[..^16], body[^16..], plaintext);
        receiveCounter++;
        return plaintext;
    }

    public void Dispose()
    {
        sendKey.Dispose();
        receiveKey.Dispose();
    }
}

internal ref struct MessageReader(ReadOnlySpan<byte> data)
{
    private readonly ReadOnlySpan<byte> data = data;
    private int offset = 1;

    public MessageType Type => (MessageType)data[0];
    public bool Has(int bytes) => offset + bytes <= data.Length;

    public byte U8() => data[offset++];

    public ushort U16()
    {
        var value = BinaryPrimitives.ReadUInt16LittleEndian(data[offset..]);
        offset += 2;
        return value;
    }

    public uint U32()
    {
        var value = BinaryPrimitives.ReadUInt32LittleEndian(data[offset..]);
        offset += 4;
        return value;
    }

    public ulong U64()
    {
        var value = BinaryPrimitives.ReadUInt64LittleEndian(data[offset..]);
        offset += 8;
        return value;
    }

    public float F32()
    {
        var value = BinaryPrimitives.ReadSingleLittleEndian(data[offset..]);
        offset += 4;
        return value;
    }

    public string Utf8Rest() => Encoding.UTF8.GetString(data[offset..]);
    public byte[] Rest() => data[offset..].ToArray();
}

internal static class Messages
{
    public static byte[] Hello(string name)
    {
        var nameBytes = Encoding.UTF8.GetBytes(name.Length > 64 ? name[..64] : name);
        return [(byte)MessageType.Hello, 2, .. nameBytes];
    }

    public static byte[] Screen(float widthMm, float heightMm)
    {
        var message = new byte[9];
        message[0] = (byte)MessageType.Screen;
        BinaryPrimitives.WriteSingleLittleEndian(message.AsSpan(1), widthMm);
        BinaryPrimitives.WriteSingleLittleEndian(message.AsSpan(5), heightMm);
        return message;
    }

    public static byte[] Leave(Injector.Exit exit)
    {
        var message = new byte[6];
        message[0] = (byte)MessageType.Leave;
        BinaryPrimitives.WriteSingleLittleEndian(message.AsSpan(1), exit.AlongMm);
        message[5] = (byte)exit.Edge;
        return message;
    }

    public static byte[] ArrangementEdit(byte[] json) => [(byte)MessageType.ArrangementEdit, .. json];

    public static byte[] Rename(byte[] json) => [(byte)MessageType.Rename, .. json];

    /// The Easy-Switch channels the keyboard and mouse use on this PC (0xFF = not connected here).
    public static byte[] Hosts(byte keyboardHost, byte mouseHost) => [(byte)MessageType.Hosts, keyboardHost, mouseHost];

    public static byte[] Stats(byte[] json) => [(byte)MessageType.Stats, .. json];

    public static byte[] Pong(ulong stamp)
    {
        var message = new byte[9];
        message[0] = (byte)MessageType.Pong;
        BinaryPrimitives.WriteUInt64LittleEndian(message.AsSpan(1), stamp);
        return message;
    }
}
