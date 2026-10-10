# Only reads passage data from stdin. No text is evaluated as code.
$ErrorActionPreference = 'Stop'
$clipboardOk = $false
try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload.textBase64))
    if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -gt 100000) {
        throw 'The passage must contain 1 to 100000 characters.'
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DungeonReader {
    [StructLayout(LayoutKind.Sequential)]
    public struct MouseInput { public int dx, dy; public uint mouseData, flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KeyboardInput { public ushort key, scan; public uint flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion {
        [FieldOffset(0)] public MouseInput mouse;
        [FieldOffset(0)] public KeyboardInput keyboard;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct Input { public uint type; public InputUnion data; }
    [DllImport("user32.dll", SetLastError=true)]
    private static extern uint SendInput(uint count, Input[] inputs, int size);
    private static Input Key(ushort key, uint flags) {
        var input = new Input(); input.type = 1;
        input.data.keyboard.key = key; input.data.keyboard.flags = flags;
        return input;
    }
    public static uint Read() {
        var inputs = new[] { Key(0xA4, 0), Key(0x70, 0), Key(0x70, 2), Key(0xA4, 2) };
        uint accepted = SendInput(4, inputs, Marshal.SizeOf(typeof(Input)));
        if (accepted != 4) {
            // Release keys even after a partially accepted sequence.
            SendInput(2, new[] { Key(0x70, 2), Key(0xA4, 2) }, Marshal.SizeOf(typeof(Input)));
        }
        return accepted;
    }
}
'@
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        try {
            [Windows.Forms.Clipboard]::SetText($text)
            $clipboardOk = $true
            break
        } catch {
            if ($attempt -eq 7) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
    Start-Sleep -Milliseconds 150
    $accepted = [DungeonReader]::Read()
    if ($accepted -ne 4) { throw "Windows accepted $accepted of 4 shortcut events." }
    @{ ok = $true; clipboardOk = $true; hotkeyOk = $true; inputEvents = $accepted;
        message = 'Passage copied and Alt+F1 sent to Speechify.' } | ConvertTo-Json -Compress
} catch {
    @{ ok = $false; clipboardOk = $clipboardOk; hotkeyOk = $false;
        message = $(if ($clipboardOk) { 'Passage copied, but the shortcut failed. Press Alt+F1 manually.' }
            else { 'Windows reader handoff failed. The prose is selected; press Alt+F1 manually.' }) } | ConvertTo-Json -Compress
    exit 1
}
