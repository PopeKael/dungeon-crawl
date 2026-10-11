using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

// Read-only DXGI adapter inventory; LUID joins capacity to WDDM counters.
public static class DungeonGpuAdapters {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Description {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Name;
        public uint Vendor, Device, Subsystem, Revision;
        public UIntPtr DedicatedVideo, DedicatedSystem, SharedSystem;
        public uint LuidLow; public int LuidHigh; public uint Flags;
    }
    public class Adapter {
        public string Name; public string Luid; public ulong Capacity; public ulong CurrentUsage; public ulong Budget; public bool MemoryAvailable; public bool Software;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct VideoMemoryInfo {
        public ulong Budget, CurrentUsage, AvailableForReservation, CurrentReservation;
    }
    [DllImport("dxgi.dll", CallingConvention = CallingConvention.StdCall)]
    private static extern int CreateDXGIFactory1(ref Guid iid, out IntPtr factory);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int EnumAdapter(IntPtr self, uint index, out IntPtr adapter);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetDescription(IntPtr self, out Description description);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int QueryInterface(IntPtr self, ref Guid iid, out IntPtr value);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int QueryVideoMemoryInfo(IntPtr self, uint node, int segmentGroup, out VideoMemoryInfo info);
    private static T Method<T>(IntPtr obj, int slot) {
        return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(Marshal.ReadIntPtr(obj), slot * IntPtr.Size), typeof(T));
    }
    public static Adapter[] Read() {
        var iid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
        IntPtr factory;
        Marshal.ThrowExceptionForHR(CreateDXGIFactory1(ref iid, out factory));
        var result = new List<Adapter>();
        try {
            var enumerate = Method<EnumAdapter>(factory, 12);
            for (uint index = 0; index < 32; index++) {
                IntPtr adapter;
                int hr = enumerate(factory, index, out adapter);
                if (hr == unchecked((int)0x887A0002)) break;
                Marshal.ThrowExceptionForHR(hr);
                try {
                    Description desc;
                    Marshal.ThrowExceptionForHR(Method<GetDescription>(adapter, 10)(adapter, out desc));
                    var item = new Adapter {
                        Name = desc.Name, Capacity = desc.DedicatedVideo.ToUInt64(), Software = (desc.Flags & 2) != 0,
                        Luid = string.Format("luid_0x{0:x8}_0x{1:x8}", unchecked((uint)desc.LuidHigh), desc.LuidLow)
                    };
                    // IDXGIAdapter3 reports current local-segment usage without relying
                    // on optional PowerShell performance-counter providers.
                    var adapter3Iid = new Guid("645967A4-1392-4310-A798-8053CE3E93FD");
                    IntPtr adapter3;
                    if (Method<QueryInterface>(adapter, 0)(adapter, ref adapter3Iid, out adapter3) == 0) {
                        try {
                            VideoMemoryInfo memory;
                            int memoryHr = Method<QueryVideoMemoryInfo>(adapter3, 14)(adapter3, 0, 0, out memory);
                            if (memoryHr >= 0) {
                                item.CurrentUsage = memory.CurrentUsage;
                                item.Budget = memory.Budget;
                                item.MemoryAvailable = true;
                            }
                        } finally { Marshal.Release(adapter3); }
                    }
                    result.Add(item);
                } finally { Marshal.Release(adapter); }
            }
        } finally { Marshal.Release(factory); }
        return result.ToArray();
    }
}

public static class DungeonSystemMemory {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct MEMORYSTATUSEX {
        public uint dwLength, dwMemoryLoad;
        public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX buffer);
    public static ulong AvailablePhysicalBytes() {
        var status = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)) };
        if (!GlobalMemoryStatusEx(ref status)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return status.ullAvailPhys;
    }
}
