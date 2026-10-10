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
        public string Name; public string Luid; public ulong Capacity; public bool Software;
    }
    [DllImport("dxgi.dll", CallingConvention = CallingConvention.StdCall)]
    private static extern int CreateDXGIFactory1(ref Guid iid, out IntPtr factory);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int EnumAdapter(IntPtr self, uint index, out IntPtr adapter);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetDescription(IntPtr self, out Description description);
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
                    result.Add(new Adapter {
                        Name = desc.Name, Capacity = desc.DedicatedVideo.ToUInt64(), Software = (desc.Flags & 2) != 0,
                        Luid = string.Format("luid_0x{0:x8}_0x{1:x8}", unchecked((uint)desc.LuidHigh), desc.LuidLow)
                    });
                } finally { Marshal.Release(adapter); }
            }
        } finally { Marshal.Release(factory); }
        return result.ToArray();
    }
}
