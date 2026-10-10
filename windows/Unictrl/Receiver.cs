using System.Buffers.Binary;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;

namespace Unictrl;

/// Connects out to the Mac (no inbound firewall rule needed), then replays what it forwards.
internal sealed class Receiver : IDisposable
{
    private readonly Settings settings;
    private readonly Injector injector;
    private readonly Action<string> status;
    private readonly CancellationTokenSource lifetime = new();
    private readonly object sendGate = new();
    private TcpClient? client;
    private Action<byte[]>? send;
    private DateTime lastDiscovery = DateTime.MinValue;
    private readonly MoveStats moveStats = new();
    private DateTime environmentAt = DateTime.MinValue;
    /// Diagnostics for delay spikes: when the previous message was done, and how long it took.
    private long lastDoneUs;
    private double lastProcessMs;
    private DateTime lastSpikeLog = DateTime.MinValue;

    /// Raised on the receiver thread after discovery moved the Mac to a new address.
    public event Action? MacChanged;
    /// Raised on the receiver thread when a session with the Mac is established.
    public event Action? Connected;
    /// Raised on the receiver thread when the Mac sends the screen arrangement.
    public event Action<ArrangementInfo?>? ArrangementChanged;

    /// The latest arrangement from the Mac, if connected.
    public ArrangementInfo? Arrangement { get; private set; }
    /// Raised on the receiver thread when the Mac reports how the pointer is doing here (null: disconnected).
    public event Action<QualityInfo?>? QualityChanged;
    /// The Mac's latest report, with the last checklist it sent.
    public QualityInfo? Quality { get; private set; }

    /// Asks the Mac to rename a screen; it answers with the arrangement carrying the new name.
    public void Rename(string id, string name)
    {
        try { send?.Invoke(Messages.Rename(ArrangementInfo.Rename(id, name))); }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or InvalidOperationException) { }
    }

    /// Asks the Mac to move screens; it answers with the arrangement it saved.
    public void EditArrangement(IEnumerable<string> order, IReadOnlyDictionary<string, double> offsets)
    {
        try { send?.Invoke(Messages.ArrangementEdit(ArrangementInfo.Edit(order, offsets))); }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or InvalidOperationException) { }
    }

    public Receiver(Settings settings, Action<string> status)
    {
        this.settings = settings;
        this.status = status;
        injector = new Injector(settings);
    }

    public void Start()
    {
        var thread = new Thread(Run) { IsBackground = true, Name = "Unictrl receiver", Priority = ThreadPriority.AboveNormal };
        thread.Start();
    }

    private void Run()
    {
        while (!lifetime.IsCancellationRequested)
        {
            try
            {
                status("Connecting to Mac…");
                Session();
            }
            catch (Exception ex) when (!lifetime.IsCancellationRequested)
            {
                Log.Write("session_ended", ex.GetType().Name + ": " + ex.Message);
                if (ex is NotPairedException)
                {
                    status("This Mac no longer has this PC paired. Pair again.");
                    lifetime.Token.WaitHandle.WaitOne(15_000); // no point asking every 1.5 s
                }
                else if (ex is CryptographicException)
                {
                    status("Not paired with this Mac. Pair again.");
                }
                else
                {
                    status("Looking for your Mac…");
                    Rediscover();
                }
            }
            catch { }
            finally
            {
                send = null;
                if (Arrangement is not null)
                {
                    Arrangement = null;
                    ArrangementChanged?.Invoke(null);
                }
                if (Quality is not null)
                {
                    Quality = null;
                    QualityChanged?.Invoke(null);
                }
                injector.Leave("disconnected");
                client?.Dispose();
                client = null;
            }
            lifetime.Token.WaitHandle.WaitOne(1500);
        }
    }

    /// The Mac's address may have changed (DHCP, another network): ask the LAN, at most every 10 s.
    private void Rediscover()
    {
        if (DateTime.UtcNow - lastDiscovery < TimeSpan.FromSeconds(10)) return;
        lastDiscovery = DateTime.UtcNow;
        var macs = Discovery.Find(TimeSpan.FromMilliseconds(1200));
        var mac = macs.FirstOrDefault(m => m.Id == settings.MacId)
                  ?? (string.IsNullOrEmpty(settings.MacId) && macs.Count == 1 ? macs[0] : null);
        if (mac is null || (mac.Address == settings.MacAddress && mac.Id == settings.MacId && mac.Port == settings.Port)) return;
        Log.Write("mac_moved", $"id={mac.Id}");
        settings.MacAddress = mac.Address;
        settings.MacId = mac.Id;
        settings.MacName = mac.Name;
        settings.Port = mac.Port;
        settings.Save();
        MacChanged?.Invoke();
    }

    private void Session()
    {
        if (string.IsNullOrWhiteSpace(settings.MacAddress)) throw new SocketException((int)SocketError.HostNotFound);
        client = new TcpClient { NoDelay = true };
        client.ConnectAsync(settings.MacAddress, settings.Port, lifetime.Token).AsTask().Wait(lifetime.Token);
        var stream = client.GetStream();
        // The Mac answers the handshake at once and then pings every 0.5 s. Without a timeout, a
        // connection the Mac already dropped (a Wi-Fi blip) blocks reads forever and the PC never reconnects.
        stream.ReadTimeout = 4000;

        var clientSalt = RandomNumberGenerator.GetBytes(SecureChannel.SaltLength);
        stream.Write([.. SecureChannel.MagicV2, .. clientSalt, .. settings.DeviceIdBytes]);
        var handshake = new byte[SecureChannel.Magic.Length + SecureChannel.SaltLength];
        stream.ReadExactly(handshake, 0, SecureChannel.Magic.Length);
        if (handshake.AsSpan(0, SecureChannel.Magic.Length).SequenceEqual(SecureChannel.NotPaired))
            throw new NotPairedException();
        stream.ReadExactly(handshake, SecureChannel.Magic.Length, SecureChannel.SaltLength);
        if (!handshake.AsSpan(0, SecureChannel.Magic.Length).SequenceEqual(SecureChannel.Magic))
            throw new InvalidDataException("Not a Unictrl peer");
        using var channel = new SecureChannel(settings.PairingKey, clientSalt,
            handshake[SecureChannel.Magic.Length..], isServer: false);

        void Send(byte[] message)
        {
            // Seal inside the lock: the receiver thread, the UI and Easy-Switch tasks all send, and the
            // nonce counter and AesGcm are not thread-safe (a reused nonce or out-of-order frame).
            lock (sendGate) stream.Write(channel.Seal(message));
        }

        Send(Messages.Hello(Environment.MachineName));
        moveStats.Reset();
        environmentAt = DateTime.MinValue;
        var local = (client.Client.LocalEndPoint as IPEndPoint)?.Address;
        // Once a second, what the moves looked like here, and every 10 s this PC's network and power.
        using var statsTimer = new Timer(_ =>
        {
            if (send is null) return;
            var second = moveStats.Take();
            var refresh = DateTime.UtcNow - environmentAt > TimeSpan.FromSeconds(10);
            if (second.Moves == 0 && !refresh) return;
            PcEnvironmentInfo? environment = null;
            if (refresh)
            {
                environmentAt = DateTime.UtcNow;
                environment = PcEnvironment.Read(local);
            }
            try { Send(Messages.Stats(PcStatsMessage.Json(second, environment))); }
            catch (Exception ex) when (ex is IOException or ObjectDisposedException or InvalidOperationException) { }
        }, null, 1000, 1000);
        var header = new byte[2];
        var body = new byte[SecureChannel.MaxFrame];
        var greeted = false;
        while (!lifetime.IsCancellationRequested)
        {
            stream.ReadExactly(header);
            var length = BinaryPrimitives.ReadUInt16BigEndian(header);
            if (length < 17 || length > SecureChannel.MaxFrame) throw new InvalidDataException("Bad frame");
            stream.ReadExactly(body, 0, length);
            var arrivalUs = (long)(Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency * 1_000_000);
            var message = channel.Open(body.AsSpan(0, length));
            if (message.Length == 0) continue;
            var reader = new MessageReader(message);
            if (!greeted)
            {
                if (reader.Type != MessageType.Hello) throw new InvalidDataException("Expected hello");
                greeted = true;
                reader.U8(); // platform
                var name = reader.Utf8Rest();
                Log.Write("connected", $"peer={name}");
                var screen = Displays.Primary(settings.ScreenWidthMmOverride);
                Send(Messages.Screen((float)(screen.Bounds.Width / screen.PixelsPerMm), (float)(screen.Bounds.Height / screen.PixelsPerMm)));
                status($"Connected to {name}");
                Connected?.Invoke();
                if (string.IsNullOrEmpty(settings.MacId)) Task.Run(LearnMacId);
                send = Send;
                continue;
            }
            Dispatch(ref reader, Send, arrivalUs);
            lastDoneUs = (long)(Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency * 1_000_000);
            lastProcessMs = (lastDoneUs - arrivalUs) / 1000.0;
        }
    }

    private void Dispatch(ref MessageReader reader, Action<byte[]> send, long arrivalUs)
    {
        switch (reader.Type)
        {
            case MessageType.Enter when reader.Has(4):
                var entryMm = reader.F32();
                var fromRight = reader.Has(1) && reader.U8() == 1;
                var flags = reader.Has(1) ? reader.U8() : 0;
                bool leftOpen = (flags & 2) != 0, rightOpen = (flags & 4) != 0;
                if ((flags & 1) != 0) injector.Resume(fromRight, leftOpen, rightOpen);
                else injector.Enter(entryMm, fromRight, leftOpen, rightOpen);
                break;
            case MessageType.Move or MessageType.MoveRaw when reader.Has(8):
            {
                var raw = reader.Type == MessageType.MoveRaw;
                var (dx, dy) = (reader.F32(), reader.F32());
                uint? sentUs = reader.Has(4) ? reader.U32() : null;
                var start = Stopwatch.GetTimestamp();
                var exit = raw ? injector.MoveRaw(dx, dy) : injector.Move(dx, dy);
                var injectMs = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
                if (moveStats.Add(sentUs, arrivalUs, injectMs) is { } lateMs && DateTime.UtcNow - lastSpikeLog > TimeSpan.FromSeconds(1))
                {
                    // waited: how long this thread sat idle before the late move arrived. Near 0 with a slow
                    // previous message means the PC itself held it up; otherwise it came late off the network.
                    lastSpikeLog = DateTime.UtcNow;
                    Log.Diagnostic("delay_spike", $"late_ms={lateMs:F1} waited_ms={(arrivalUs - lastDoneUs) / 1000.0:F1} prev_process_ms={lastProcessMs:F1}");
                }
                if (exit is { } e) send(Messages.Leave(e));
                break;
            }
            case MessageType.Quality:
                if (QualityInfo.Parse(reader.Rest()) is { } quality)
                {
                    // The checklist comes only when it changed.
                    if (quality.Tips is null && Quality?.Tips is { } tips) quality = quality with { Tips = tips };
                    Quality = quality;
                    QualityChanged?.Invoke(quality);
                }
                break;
            case MessageType.Reclaim when reader.Has(2):
                var keyboardHost = reader.U8();
                var mouseHost = reader.U8();
                Log.Write("reclaim", $"keyboard={keyboardHost} mouse={mouseHost}");
                _ = Task.Run(() => LogitechHid.ReturnToMacAsync(keyboardHost, mouseHost, send));
                break;
            case MessageType.Arrangement:
                if (ArrangementInfo.Parse(reader.Rest()) is { } arrangement)
                {
                    Arrangement = arrangement;
                    ArrangementChanged?.Invoke(arrangement);
                }
                break;
            case MessageType.Button when reader.Has(2):
                injector.Button(reader.U8(), reader.U8() != 0);
                break;
            case MessageType.Wheel when reader.Has(8):
                injector.Wheel(reader.F32(), reader.F32());
                break;
            case MessageType.Key when reader.Has(4):
                injector.Key(reader.U8(), reader.U16(), reader.U8() != 0);
                break;
            case MessageType.Action when reader.Has(1):
                injector.Action(reader.U8());
                break;
            case MessageType.Ping when reader.Has(8):
                send(Messages.Pong(reader.U64()));
                break;
        }
    }

    /// Settings from before discovery have an address but no device ID; learn it once.
    private void LearnMacId()
    {
        var mac = Discovery.Find(TimeSpan.FromMilliseconds(1200)).FirstOrDefault(m => m.Address == settings.MacAddress);
        if (mac is null) return;
        settings.MacId = mac.Id;
        settings.MacName = mac.Name;
        settings.Save();
        Log.Write("mac_id_learned");
        MacChanged?.Invoke();
    }

    public void Dispose()
    {
        lifetime.Cancel();
        client?.Dispose();
    }
}

/// The Mac answered that it does not know this PC.
internal sealed class NotPairedException() : Exception("Not paired with this Mac");
