Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$nativeSource = @"
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Management;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

namespace DeckPadNative
{
    public class RawKeyEvent
    {
        public int VirtualKey;
        public int ScanCode;
        public int KeyFlags;
        public string RawDataHex;
        public int ConsumerUsage;
        public string DeviceId;
        public string DeviceName;
        public string HardwareId;
        public string DevicePath;
        public int TimestampMs;
    }

    public class GlobalKeyEvent
    {
        public int VirtualKey;
        public int TimestampMs;
    }

    public class KeyboardDeviceInfo
    {
        public string DeviceId;
        public string DeviceName;
        public string HardwareId;
        public string DevicePath;
    }

    public static class RawInputMonitor
    {
        private const int WM_INPUT = 0x00FF;
        private const int RIM_TYPEKEYBOARD = 1;
        private const int RIM_TYPEHID = 2;
        private const int RID_INPUT = 0x10000003;
        private const int RIDI_DEVICENAME = 0x20000007;
        private const int RIDEV_INPUTSINK = 0x00000100;
        private const int WM_KEYDOWN = 0x0100;
        private const int WM_SYSKEYDOWN = 0x0104;
        private const int WH_KEYBOARD_LL = 13;

        private static readonly ConcurrentQueue<RawKeyEvent> Queue = new ConcurrentQueue<RawKeyEvent>();
        private static readonly ConcurrentQueue<GlobalKeyEvent> GlobalQueue = new ConcurrentQueue<GlobalKeyEvent>();
        private static readonly ConcurrentDictionary<string, string> _nameCache =
            new ConcurrentDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private static RawInputWindow _window;
        private static IntPtr _keyboardHook = IntPtr.Zero;
        private static LowLevelKeyboardProc _keyboardProc = KeyboardHookCallback;

        public static bool Start()
        {
            if (_window != null)
            {
                return true;
            }

            _window = new RawInputWindow();
            if (!_window.Register())
            {
                return false;
            }

            _keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, _keyboardProc, GetModuleHandle(null), 0);
            return _keyboardHook != IntPtr.Zero;
        }

        public static void Stop()
        {
            if (_window == null)
            {
                return;
            }

            _window.Dispose();
            _window = null;
            _nameCache.Clear();
            GlobalKeyEvent discardedGlobal;
            while (GlobalQueue.TryDequeue(out discardedGlobal)) { }
            RawKeyEvent discardedRaw;
            while (Queue.TryDequeue(out discardedRaw)) { }

            if (_keyboardHook != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_keyboardHook);
                _keyboardHook = IntPtr.Zero;
            }
        }

        public static bool TryDequeue(out RawKeyEvent keyEvent)
        {
            return Queue.TryDequeue(out keyEvent);
        }

        public static bool TryDequeueGlobal(out GlobalKeyEvent keyEvent)
        {
            return GlobalQueue.TryDequeue(out keyEvent);
        }

        public static KeyboardDeviceInfo[] GetKeyboardDevices()
        {
            _nameCache.Clear();
            uint count = 0;
            uint size = (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICELIST));
            GetRawInputDeviceList(IntPtr.Zero, ref count, size);
            if (count == 0)
            {
                return new KeyboardDeviceInfo[0];
            }

            IntPtr listPtr = Marshal.AllocHGlobal((int)(count * size));
            try
            {
                if (GetRawInputDeviceList(listPtr, ref count, size) == uint.MaxValue)
                {
                    return new KeyboardDeviceInfo[0];
                }

                KeyboardDeviceInfo[] devices = new KeyboardDeviceInfo[count];
                int found = 0;
                for (uint i = 0; i < count; i++)
                {
                    IntPtr itemPtr = new IntPtr(listPtr.ToInt64() + (i * size));
                    RAWINPUTDEVICELIST item = (RAWINPUTDEVICELIST)Marshal.PtrToStructure(itemPtr, typeof(RAWINPUTDEVICELIST));
                    if (item.dwType != RIM_TYPEKEYBOARD)
                    {
                        continue;
                    }

                    string devicePath = GetDevicePath(item.hDevice);

                    devices[found++] = new KeyboardDeviceInfo
                    {
                        DeviceId = item.hDevice.ToInt64().ToString("X"),
                        DeviceName = GetFriendlyDeviceName(devicePath),
                        HardwareId = ExtractHardwareId(devicePath),
                        DevicePath = devicePath
                    };
                }

                KeyboardDeviceInfo[] result = new KeyboardDeviceInfo[found];
                Array.Copy(devices, result, found);
                return result;
            }
            finally
            {
                Marshal.FreeHGlobal(listPtr);
            }
        }

        private sealed class RawInputWindow : NativeWindow, IDisposable
        {
            public RawInputWindow()
            {
                CreateHandle(new CreateParams());
            }

            public bool Register()
            {
                RAWINPUTDEVICE[] devices = new RAWINPUTDEVICE[2];
                devices[0].usUsagePage = 0x01;
                devices[0].usUsage = 0x06;
                devices[0].dwFlags = RIDEV_INPUTSINK;
                devices[0].hwndTarget = this.Handle;
                devices[1].usUsagePage = 0x0C;
                devices[1].usUsage = 0x01;
                devices[1].dwFlags = RIDEV_INPUTSINK;
                devices[1].hwndTarget = this.Handle;

                return RegisterRawInputDevices(devices, (uint)devices.Length, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
            }

            protected override void WndProc(ref Message m)
            {
                if (m.Msg == WM_INPUT)
                {
                    ProcessRawInput(m.LParam);
                }

                base.WndProc(ref m);
            }

            public void Dispose()
            {
                DestroyHandle();
            }

            private static void ProcessRawInput(IntPtr hRawInput)
            {
                uint size = 0;
                GetRawInputData(hRawInput, RID_INPUT, IntPtr.Zero, ref size, (uint)Marshal.SizeOf(typeof(RAWINPUTHEADER)));
                if (size == 0)
                {
                    return;
                }

                IntPtr buffer = Marshal.AllocHGlobal((int)size);
                try
                {
                    if (GetRawInputData(hRawInput, RID_INPUT, buffer, ref size, (uint)Marshal.SizeOf(typeof(RAWINPUTHEADER))) != size)
                    {
                        return;
                    }

                    RAWINPUTHEADER header = (RAWINPUTHEADER)Marshal.PtrToStructure(buffer, typeof(RAWINPUTHEADER));
                    if (header.dwType == RIM_TYPEHID)
                    {
                        ProcessRawHidInput(buffer, header);
                        return;
                    }

                    if (header.dwType != RIM_TYPEKEYBOARD)
                    {
                        return;
                    }

                    IntPtr keyboardPtr = new IntPtr(buffer.ToInt64() + Marshal.SizeOf(typeof(RAWINPUTHEADER)));
                    RAWKEYBOARD keyboard = (RAWKEYBOARD)Marshal.PtrToStructure(keyboardPtr, typeof(RAWKEYBOARD));
                    if (keyboard.Message != WM_KEYDOWN && keyboard.Message != WM_SYSKEYDOWN)
                    {
                        return;
                    }

                    Queue.Enqueue(new RawKeyEvent
                    {
                        VirtualKey = keyboard.VKey,
                        ScanCode = keyboard.MakeCode,
                        KeyFlags = keyboard.Flags,
                        RawDataHex = "",
                        ConsumerUsage = 0,
                        DeviceId = header.hDevice.ToInt64().ToString("X"),
                        DeviceName = GetOrCacheDeviceName(header.hDevice),
                        HardwareId = ExtractHardwareId(GetDevicePath(header.hDevice)),
                        DevicePath = GetDevicePath(header.hDevice),
                        TimestampMs = Environment.TickCount
                    });
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }

            private static void ProcessRawHidInput(IntPtr buffer, RAWINPUTHEADER header)
            {
                IntPtr hidPtr = new IntPtr(buffer.ToInt64() + Marshal.SizeOf(typeof(RAWINPUTHEADER)));
                RAWHID hid = (RAWHID)Marshal.PtrToStructure(hidPtr, typeof(RAWHID));
                if (hid.dwSizeHid <= 0 || hid.dwCount <= 0)
                {
                    return;
                }

                int dataLength = hid.dwSizeHid * hid.dwCount;
                int dataOffset = Marshal.SizeOf(typeof(RAWINPUTHEADER)) + Marshal.OffsetOf(typeof(RAWHID), "bRawData").ToInt32();
                byte[] data = new byte[dataLength];
                Marshal.Copy(new IntPtr(buffer.ToInt64() + dataOffset), data, 0, dataLength);

                int virtualKey;
                int consumerUsage;
                if (!TryMapConsumerUsage(data, out virtualKey, out consumerUsage))
                {
                    return;
                }

                string devicePath = GetDevicePath(header.hDevice);
                Queue.Enqueue(new RawKeyEvent
                {
                    VirtualKey = virtualKey,
                    ScanCode = 0,
                    KeyFlags = 0,
                    RawDataHex = BytesToHex(data),
                    ConsumerUsage = consumerUsage,
                    DeviceId = header.hDevice.ToInt64().ToString("X"),
                    DeviceName = GetOrCacheDeviceName(header.hDevice),
                    HardwareId = ExtractHardwareId(devicePath),
                    DevicePath = devicePath,
                    TimestampMs = Environment.TickCount
                });
            }

            private static string BytesToHex(byte[] data)
            {
                if (data == null || data.Length == 0)
                {
                    return "";
                }

                char[] c = new char[data.Length * 2];
                int b;
                for (int i = 0; i < data.Length; i++)
                {
                    b = data[i] >> 4;
                    c[i * 2] = (char)(55 + b + (((b - 10) >> 31) & -7));
                    b = data[i] & 0xF;
                    c[i * 2 + 1] = (char)(55 + b + (((b - 10) >> 31) & -7));
                }

                return new string(c);
            }

            private static bool TryMapConsumerUsage(byte[] data, out int virtualKey, out int consumerUsage)
            {
                virtualKey = 0;
                consumerUsage = 0;
                bool hasNonZero = false;
                for (int i = 0; i < data.Length; i++)
                {
                    if (data[i] != 0)
                    {
                        hasNonZero = true;
                        break;
                    }
                }

                if (!hasNonZero)
                {
                    return false;
                }

                for (int i = 0; i + 1 < data.Length; i++)
                {
                    int usage = data[i] | (data[i + 1] << 8);
                    if (TryMapConsumerUsageId(usage, out virtualKey))
                    {
                        consumerUsage = usage;
                        return true;
                    }
                }

                for (int i = 0; i < data.Length; i++)
                {
                    if (TryMapConsumerUsageId(data[i], out virtualKey))
                    {
                        consumerUsage = data[i];
                        return true;
                    }
                }

                return false;
            }

            private static bool TryMapConsumerUsageId(int usage, out int virtualKey)
            {
                virtualKey = 0;
                switch (usage)
                {
                    case 0x00B0:
                        virtualKey = 176;
                        return true;
                    case 0x00B1:
                        virtualKey = 177;
                        return true;
                    case 0x00CD:
                        virtualKey = 179;
                        return true;
                    case 0x00E2:
                        virtualKey = 173;
                        return true;
                    case 0x00E9:
                        virtualKey = 175;
                        return true;
                    case 0x00EA:
                        virtualKey = 174;
                        return true;
                    default:
                        return false;
                }
            }
        }

        private static IntPtr KeyboardHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                int message = wParam.ToInt32();
                if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN)
                {
                    KBDLLHOOKSTRUCT data = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                    if ((data.flags & 0x10) != 0)
                    {
                        return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
                    }

                    GlobalQueue.Enqueue(new GlobalKeyEvent
                    {
                        VirtualKey = data.vkCode,
                        TimestampMs = Environment.TickCount
                    });
                }
            }

            return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
        }

        private static string GetOrCacheDeviceName(IntPtr deviceHandle)
        {
            string key = deviceHandle.ToInt64().ToString("X");
            return _nameCache.GetOrAdd(key, _ => GetFriendlyDeviceName(GetDevicePath(deviceHandle)));
        }

        private static string GetDevicePath(IntPtr deviceHandle)
        {
            uint size = 0;
            GetRawInputDeviceInfo(deviceHandle, RIDI_DEVICENAME, IntPtr.Zero, ref size);
            if (size == 0)
            {
                return "Unknown keyboard";
            }

            IntPtr namePtr = Marshal.AllocHGlobal((int)(size * 2));
            try
            {
                if (GetRawInputDeviceInfo(deviceHandle, RIDI_DEVICENAME, namePtr, ref size) <= 0)
                {
                    return "Unknown keyboard";
                }

                string name = Marshal.PtrToStringAuto(namePtr);
                return string.IsNullOrWhiteSpace(name) ? "Unknown keyboard" : name;
            }
            finally
            {
                Marshal.FreeHGlobal(namePtr);
            }
        }

        private static string GetFriendlyDeviceName(string devicePath)
        {
            if (string.IsNullOrWhiteSpace(devicePath) || devicePath == "Unknown keyboard")
            {
                return "Unknown keyboard";
            }

            if (devicePath.StartsWith(@"\\?\Microsoft Keyboard", StringComparison.OrdinalIgnoreCase))
            {
                return "Microsoft Keyboard";
            }

            string instanceId = ToDeviceInstanceId(devicePath);
            if (!string.IsNullOrWhiteSpace(instanceId))
            {
                string pnpName = TryGetPnpFriendlyName(instanceId);
                if (!string.IsNullOrWhiteSpace(pnpName))
                {
                    return pnpName;
                }
            }

            string hardwareId = ExtractHardwareId(devicePath);
            if (!string.IsNullOrWhiteSpace(hardwareId))
            {
                return "Keyboard " + hardwareId;
            }

            return devicePath;
        }

        private static string TryGetPnpFriendlyName(string instanceId)
        {
            try
            {
                string escaped = instanceId.Replace("'", "''");
                string query = string.Format(
                    CultureInfo.InvariantCulture,
                    "SELECT Name, Caption, Description FROM Win32_PnPEntity WHERE DeviceID = '{0}'",
                    escaped);
                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(query))
                {
                    foreach (ManagementObject device in searcher.Get())
                    {
                        string name = Convert.ToString(device["Name"], CultureInfo.InvariantCulture);
                        if (!string.IsNullOrWhiteSpace(name)) return name;
                        string caption = Convert.ToString(device["Caption"], CultureInfo.InvariantCulture);
                        if (!string.IsNullOrWhiteSpace(caption)) return caption;
                        string description = Convert.ToString(device["Description"], CultureInfo.InvariantCulture);
                        if (!string.IsNullOrWhiteSpace(description)) return description;
                    }
                }
            }
            catch
            {
            }

            return null;
        }

        private static string ToDeviceInstanceId(string devicePath)
        {
            if (string.IsNullOrWhiteSpace(devicePath))
            {
                return null;
            }

            string trimmed = devicePath;
            if (trimmed.StartsWith(@"\\?\"))
            {
                trimmed = trimmed.Substring(4);
            }

            int guidStart = trimmed.IndexOf("#{", StringComparison.OrdinalIgnoreCase);
            if (guidStart >= 0)
            {
                trimmed = trimmed.Substring(0, guidStart);
            }

            trimmed = trimmed.Replace('#', '\\');
            return trimmed;
        }

        private static string ExtractHardwareId(string devicePath)
        {
            if (string.IsNullOrWhiteSpace(devicePath))
            {
                return null;
            }

            Match match = Regex.Match(devicePath, @"VID_([0-9A-F]{4}).*PID_([0-9A-F]{4})", RegexOptions.IgnoreCase);
            if (match.Success)
            {
                return string.Format(
                    CultureInfo.InvariantCulture,
                    "VID {0} PID {1}",
                    match.Groups[1].Value.ToUpperInvariant(),
                    match.Groups[2].Value.ToUpperInvariant()
                );
            }

            return null;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RAWINPUTDEVICE
        {
            public ushort usUsagePage;
            public ushort usUsage;
            public int dwFlags;
            public IntPtr hwndTarget;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RAWINPUTHEADER
        {
            public int dwType;
            public int dwSize;
            public IntPtr hDevice;
            public IntPtr wParam;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RAWKEYBOARD
        {
            public ushort MakeCode;
            public ushort Flags;
            public ushort Reserved;
            public ushort VKey;
            public int Message;
            public int ExtraInformation;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RAWHID
        {
            public int dwSizeHid;
            public int dwCount;
            public byte bRawData;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RAWINPUTDEVICELIST
        {
            public IntPtr hDevice;
            public int dwType;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KBDLLHOOKSTRUCT
        {
            public int vkCode;
            public int scanCode;
            public int flags;
            public int time;
            public IntPtr dwExtraInfo;
        }

        private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool RegisterRawInputDevices(
            RAWINPUTDEVICE[] pRawInputDevices,
            uint uiNumDevices,
            uint cbSize
        );

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetRawInputData(
            IntPtr hRawInput,
            int uiCommand,
            IntPtr pData,
            ref uint pcbSize,
            uint cbSizeHeader
        );

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        private static extern uint GetRawInputDeviceInfo(
            IntPtr hDevice,
            int uiCommand,
            IntPtr pData,
            ref uint pcbSize
        );

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetRawInputDeviceList(
            IntPtr pRawInputDeviceList,
            ref uint uiNumDevices,
            uint cbSize
        );

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);
    }

    public static class WindowActions
    {
        private const int SW_RESTORE = 9;
        private const byte VK_MEDIA_NEXT_TRACK = 0xB0;
        private const byte VK_MEDIA_PREV_TRACK = 0xB1;
        private const byte VK_MEDIA_PLAY_PAUSE = 0xB3;
        private const int KEYEVENTF_KEYUP = 0x0002;

        public static bool FocusOrLaunch(string executable, string processName)
        {
            if (FocusProcess(processName)) return true;
            if (string.IsNullOrWhiteSpace(executable)) return false;
            if (!TryStartProcess(executable)) return false;
            ThreadPool.QueueUserWorkItem(_ => { Thread.Sleep(1200); FocusProcess(processName); });
            return true;
        }

        private static bool TryStartProcess(string executable)
        {
            if (string.IsNullOrWhiteSpace(executable)) return false;

            string[] candidates = executable.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                ? new string[] { executable }
                : new string[] { executable, executable + ".exe", executable + ":" };

            foreach (string candidate in candidates)
            {
                try
                {
                    ProcessStartInfo startInfo = new ProcessStartInfo(candidate);
                    startInfo.UseShellExecute = true;
                    Process.Start(startInfo);
                    return true;
                }
                catch
                {
                }
            }

            return false;
        }

        public static bool FocusProcess(string processName)
        {
            if (string.IsNullOrWhiteSpace(processName))
            {
                return false;
            }

            foreach (Process process in Process.GetProcessesByName(processName))
            {
                if (process.MainWindowHandle != IntPtr.Zero)
                {
                    ShowWindowAsync(process.MainWindowHandle, SW_RESTORE);
                    return SetForegroundWindow(process.MainWindowHandle);
                }
            }

            return false;
        }

        public static void SendMediaPlayPause()
        {
            SendMediaKey(VK_MEDIA_PLAY_PAUSE);
        }

        public static void SendMediaNextTrack()
        {
            SendMediaKey(VK_MEDIA_NEXT_TRACK);
        }

        public static void SendMediaPreviousTrack()
        {
            SendMediaKey(VK_MEDIA_PREV_TRACK);
        }

        private static void SendMediaKey(byte virtualKey)
        {
            keybd_event(virtualKey, 0, 0, 0);
            keybd_event(virtualKey, 0, KEYEVENTF_KEYUP, 0);
        }

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern void keybd_event(byte bVk, byte bScan, int dwFlags, int dwExtraInfo);
    }

    public static class AudioSessionActions
    {
        private const int CLSCTX_ALL = 23;

        public static bool AdjustProcessVolume(string processName, float delta, out float volumePercent)
        {
            volumePercent = 0;
            IMMDeviceEnumerator enumerator = null;

            try
            {
                enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                ERole[] roles = new ERole[] { ERole.eMultimedia, ERole.eConsole, ERole.eCommunications };
                foreach (ERole role in roles)
                {
                    IMMDevice device = null;
                    try
                    {
                        if (enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, role, out device) == 0 &&
                            TryAdjustProcessVolumeOnDevice(device, processName, delta, out volumePercent))
                        {
                            return true;
                        }
                    }
                    finally
                    {
                        if (device != null) Marshal.ReleaseComObject(device);
                    }
                }
            }
            finally
            {
                if (enumerator != null) Marshal.ReleaseComObject(enumerator);
            }

            return false;
        }

        private static bool TryAdjustProcessVolumeOnDevice(IMMDevice device, string processName, float delta, out float volumePercent)
        {
            volumePercent = 0;
            object managerObject = null;
            IAudioSessionManager2 manager = null;
            IAudioSessionEnumerator sessionEnumerator = null;

            try
            {
                Guid sessionManagerGuid = typeof(IAudioSessionManager2).GUID;
                Marshal.ThrowExceptionForHR(device.Activate(ref sessionManagerGuid, CLSCTX_ALL, IntPtr.Zero, out managerObject));
                manager = (IAudioSessionManager2)managerObject;

                Marshal.ThrowExceptionForHR(manager.GetSessionEnumerator(out sessionEnumerator));
                int sessionCount;
                Marshal.ThrowExceptionForHR(sessionEnumerator.GetCount(out sessionCount));

                for (int i = 0; i < sessionCount; i++)
                {
                    IAudioSessionControl sessionControl = null;
                    IAudioSessionControl2 sessionControl2 = null;
                    ISimpleAudioVolume simpleVolume = null;

                    try
                    {
                        Marshal.ThrowExceptionForHR(sessionEnumerator.GetSession(i, out sessionControl));
                        sessionControl2 = (IAudioSessionControl2)sessionControl;

                        uint processId;
                        Marshal.ThrowExceptionForHR(sessionControl2.GetProcessId(out processId));
                        if (processId == 0)
                        {
                            continue;
                        }

                        Process process;
                        try
                        {
                            process = Process.GetProcessById((int)processId);
                        }
                        catch
                        {
                            continue;
                        }

                        string displayName = null;
                        string sessionIdentifier = null;
                        string sessionInstanceIdentifier = null;

                        try { sessionControl.GetDisplayName(out displayName); } catch { }
                        try { sessionControl2.GetSessionIdentifier(out sessionIdentifier); } catch { }
                        try { sessionControl2.GetSessionInstanceIdentifier(out sessionInstanceIdentifier); } catch { }

                        if (!IsMatchingSession(processName, process.ProcessName, displayName, sessionIdentifier, sessionInstanceIdentifier))
                        {
                            continue;
                        }

                        simpleVolume = (ISimpleAudioVolume)sessionControl;
                        float currentVolume;
                        Marshal.ThrowExceptionForHR(simpleVolume.GetMasterVolume(out currentVolume));

                        float nextVolume = currentVolume + delta;
                        if (nextVolume < 0f) nextVolume = 0f;
                        if (nextVolume > 1f) nextVolume = 1f;

                        Marshal.ThrowExceptionForHR(simpleVolume.SetMasterVolume(nextVolume, Guid.Empty));
                        volumePercent = nextVolume * 100f;
                        return true;
                    }
                    finally
                    {
                        if (simpleVolume != null) Marshal.ReleaseComObject(simpleVolume);
                        if (sessionControl2 != null) Marshal.ReleaseComObject(sessionControl2);
                        if (sessionControl != null) Marshal.ReleaseComObject(sessionControl);
                    }
                }
            }
            finally
            {
                if (sessionEnumerator != null) Marshal.ReleaseComObject(sessionEnumerator);
                if (manager != null) Marshal.ReleaseComObject(manager);
                if (managerObject != null) Marshal.ReleaseComObject(managerObject);
            }

            return false;
        }

        private static bool IsMatchingSession(
            string targetProcessName,
            string processName,
            string displayName,
            string sessionIdentifier,
            string sessionInstanceIdentifier)
        {
            if (!string.IsNullOrWhiteSpace(processName) &&
                processName.Equals(targetProcessName, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            return ContainsToken(displayName, targetProcessName) ||
                   ContainsToken(sessionIdentifier, targetProcessName) ||
                   ContainsToken(sessionInstanceIdentifier, targetProcessName);
        }

        private static bool ContainsToken(string source, string token)
        {
            if (string.IsNullOrWhiteSpace(source) || string.IsNullOrWhiteSpace(token))
            {
                return false;
            }

            return source.IndexOf(token, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        [ComImport]
        [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
        private class MMDeviceEnumeratorComObject
        {
        }

        private enum EDataFlow
        {
            eRender,
            eCapture,
            eAll
        }

        private enum ERole
        {
            eConsole,
            eMultimedia,
            eCommunications
        }

        [ComImport]
        [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDeviceEnumerator
        {
            int NotImpl1();
            int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice ppDevice);
        }

        [ComImport]
        [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDevice
        {
            int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        }

        [ComImport]
        [Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAudioSessionManager2
        {
            int NotImpl0();
            int NotImpl1();
            int GetSessionEnumerator(out IAudioSessionEnumerator SessionEnum);
            int NotImpl2();
            int NotImpl3();
        }

        [ComImport]
        [Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAudioSessionEnumerator
        {
            int GetCount(out int SessionCount);
            int GetSession(int SessionCount, out IAudioSessionControl Session);
        }

        [ComImport]
        [Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAudioSessionControl
        {
            int GetState(out int pRetVal);
            int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
            int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string Value, Guid EventContext);
            int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
            int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string Value, Guid EventContext);
            int GetGroupingParam(out Guid pRetVal);
            int SetGroupingParam(Guid Override, Guid EventContext);
            int RegisterAudioSessionNotification(IntPtr NewNotifications);
            int UnregisterAudioSessionNotification(IntPtr NewNotifications);
        }

        [ComImport]
        [Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAudioSessionControl2
        {
            int GetState(out int pRetVal);
            int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
            int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string Value, Guid EventContext);
            int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
            int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string Value, Guid EventContext);
            int GetGroupingParam(out Guid pRetVal);
            int SetGroupingParam(Guid Override, Guid EventContext);
            int RegisterAudioSessionNotification(IntPtr NewNotifications);
            int UnregisterAudioSessionNotification(IntPtr NewNotifications);
            int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
            int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
            int GetProcessId(out uint pRetVal);
            int IsSystemSoundsSession();
            int SetDuckingPreference(bool optOut);
        }

        [ComImport]
        [Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface ISimpleAudioVolume
        {
            int SetMasterVolume(float fLevel, Guid EventContext);
            int GetMasterVolume(out float pfLevel);
            int SetMute(bool bMute, Guid EventContext);
            int GetMute(out bool pbMute);
        }
    }
}
"@

Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies @('System.dll', 'System.Windows.Forms.dll', 'System.Management.dll')
