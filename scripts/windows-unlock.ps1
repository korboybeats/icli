[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{16,64}$')]
    [string] $DeviceUDID,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string] $Distribution,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^/[A-Za-z0-9_./-]+$')]
    [string] $SshWrapper,
    [switch] $StoreFromStdin,
    [switch] $ProvisionPhone,
    [switch] $Check
)

$ErrorActionPreference = 'Stop'
if (([int]$StoreFromStdin.IsPresent + [int]$Check.IsPresent + [int]$ProvisionPhone.IsPresent) -gt 1) {
    throw 'Choose Windows storage, phone provisioning or preflight.'
}
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false, $true)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# Only metadata is passed as arguments. Secret bytes never enter a command
# string, a PowerShell variable, stdout, or a temporary file.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;

public static class IcliWindowsVault {
    private const string Format = "icli.passcode.utf16le.v1";
    private static readonly Encoding Unicode = new UnicodeEncoding(false, false, true);
    private static readonly Encoding Utf8 = new UTF8Encoding(false, true);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential {
        public uint Flags, Type;
        public string TargetName, Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWriteW(ref Credential credential, uint flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredReadW(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr credential);

    private static void Wipe(byte[] bytes) {
        if (bytes != null) Array.Clear(bytes, 0, bytes.Length);
    }
    private static void Validate(byte[] bytes) {
        if (bytes.Length < 1 || bytes.Length > 128 || Array.IndexOf(bytes, (byte)0) >= 0 ||
            Array.IndexOf(bytes, (byte)10) >= 0 || Array.IndexOf(bytes, (byte)13) >= 0)
            throw new InvalidOperationException("Passcode must be 1-128 UTF-8 bytes without NUL or newline.");
    }
    public static void Store(string target) {
        using (var secret = new SecureString()) {
            int character;
            while ((character = Console.In.Read()) >= 0 && character != 10 && character != 13) {
                if (secret.Length >= 128 || character == 0)
                    throw new InvalidOperationException("Invalid passcode input.");
                secret.AppendChar((char)character);
            }
            character = 0;
            IntPtr pointer = Marshal.SecureStringToCoTaskMemUnicode(secret);
            byte[] unicode = new byte[secret.Length * 2], utf8 = null;
            try {
                Marshal.Copy(pointer, unicode, 0, unicode.Length);
                utf8 = Encoding.Convert(Unicode, Utf8, unicode);
                Validate(utf8);
                var credential = new Credential {
                    Type = 1, TargetName = target, Comment = Format,
                    CredentialBlobSize = (uint)unicode.Length, CredentialBlob = pointer,
                    Persist = 2, UserName = "device-passcode"
                };
                if (!CredWriteW(ref credential, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally {
                Wipe(utf8); Wipe(unicode);
                Marshal.ZeroFreeCoTaskMemUnicode(pointer);
            }
        }
    }
    private static byte[] Read(string target) {
        IntPtr allocation;
        if (!CredReadW(target, 1, 0, out allocation)) throw new Win32Exception(Marshal.GetLastWin32Error());
        byte[] unicode = null, utf8 = null;
        Credential credential = new Credential();
        try {
            credential = (Credential)Marshal.PtrToStructure(allocation, typeof(Credential));
            if (credential.Comment != Format || credential.CredentialBlobSize == 0 ||
                credential.CredentialBlobSize > 256 || credential.CredentialBlobSize % 2 != 0)
                throw new InvalidOperationException("Unsupported icli credential format.");
            unicode = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, unicode, 0, unicode.Length);
            utf8 = Encoding.Convert(Unicode, Utf8, unicode);
            Validate(utf8);
            byte[] result = utf8;
            utf8 = null;
            return result;
        } finally {
            Wipe(unicode); Wipe(utf8);
            for (uint i = 0; i < credential.CredentialBlobSize; i++)
                Marshal.WriteByte(credential.CredentialBlob, (int)i, 0);
            CredFree(allocation);
        }
    }
    public static int Unlock(string target, string device, string distribution, string wrapper, bool check, bool provision) {
            // All variable arguments have been restricted to safe ASCII by
            // PowerShell validation. This is a native launch, without cmd.exe.
            // Verify identity and run icli on the same SSH connection.
            string remote = "actual=$(/var/jb/usr/bin/deviceinfo uniqueid) && test x$actual = x" + device +
                " || { echo Device-identity-check-failed >&2; exit 6; }; printf 'ICLI_DEVICE_VERIFIED\\n'; exec /var/jb/usr/bin/icli " +
                (provision ? "unlock --store-from-stdin" : "device passcode unlock --passcode-stdin --dismiss" +
                (check ? " --check" : ""));
            var info = new ProcessStartInfo {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "wsl.exe"),
                Arguments = "--distribution " + distribution + " --exec " + wrapper + " \"" + remote + "\"",
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Utf8, StandardErrorEncoding = Utf8
            };
            using (var process = Process.Start(info)) {
                var error = process.StandardError.ReadToEndAsync();
                // Do not even read the credential until this very connection
                // has confirmed identity. A mismatch transmits no secret.
                string ready = process.StandardOutput.ReadLine();
                if (ready != "ICLI_DEVICE_VERIFIED") {
                    process.StandardInput.BaseStream.Close();
                    string rest = process.StandardOutput.ReadToEnd();
                    process.WaitForExit();
                    if (ready != null) Console.Out.WriteLine(ready);
                    Console.Out.Write(rest);
                    Console.Error.Write(error.Result);
                    return 6;
                }
                var output = process.StandardOutput.ReadToEndAsync();
                byte[] secret = null;
                try {
                    secret = Read(target);
                    process.StandardInput.BaseStream.Write(secret, 0, secret.Length);
                    process.StandardInput.BaseStream.WriteByte(10);
                } finally {
                    Wipe(secret);
                    process.StandardInput.BaseStream.Close();
                }
                process.WaitForExit();
                Console.Out.Write(output.Result);
                Console.Error.Write(error.Result);
                return process.ExitCode;
            }
    }
}
'@

$target = 'Korboy.icli.Passcode/' + $DeviceUDID
if ($StoreFromStdin) {
    [IcliWindowsVault]::Store($target)
    [Console]::WriteLine('Stored icli credential in the current Windows user vault.')
    exit 0
}
exit [IcliWindowsVault]::Unlock($target, $DeviceUDID, $Distribution, $SshWrapper, $Check.IsPresent, $ProvisionPhone.IsPresent)
