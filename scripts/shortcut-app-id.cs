using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class DungeonShortcutIdentity {
    [StructLayout(LayoutKind.Sequential)]
    private struct Key { public Guid Format; public uint Id; }
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    private struct Value { [FieldOffset(0)] public ushort Type; [FieldOffset(8)] public IntPtr Text; }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface Store {
        void GetCount(out uint count);
        void GetAt(uint index, out Key key);
        void GetValue(ref Key key, out Value value);
        void SetValue(ref Key key, ref Value value);
        void Commit();
    }
    public static void Set(string shortcut, string appId) {
        object link = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
        var value = new Value { Type = 31, Text = Marshal.StringToCoTaskMemUni(appId) };
        try {
            ((IPersistFile)link).Load(shortcut, 2);
            var key = new Key { Format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), Id = 5 };
            ((Store)link).SetValue(ref key, ref value);
            ((Store)link).Commit();
            ((IPersistFile)link).Save(shortcut, true);
        } finally { Marshal.FreeCoTaskMem(value.Text); Marshal.FinalReleaseComObject(link); }
    }
}
