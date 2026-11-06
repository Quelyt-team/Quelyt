param(
    [string]$ProjectDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OcrSmokeNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryExW(string file, IntPtr reserved, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true)]
    public static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32.dll")] public static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll")] public static extern uint GetACP();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate IntPtr Create();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void Delete(IntPtr api);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int Init(IntPtr api, IntPtr data, IntPtr language, int mode);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void SetImage(IntPtr api, IntPtr pixels, int width, int height, int channels, int stride);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate IntPtr GetText(IntPtr api);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void DeleteText(IntPtr text);
}
'@

function Get-OcrFunction([IntPtr]$Library, [string]$Name, [type]$DelegateType) {
    $address = [OcrSmokeNative]::GetProcAddress($Library, $Name)
    if ($address -eq [IntPtr]::Zero) { throw "Missing native symbol $Name" }
    [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($address, $DelegateType)
}
function New-NativeString([string]$Text) {
    # The app manifest opts into UTF-8. This smoke script runs in PowerShell's
    # own process and therefore must honor PowerShell's current Windows ACP.
    $encoding = [Text.Encoding]::GetEncoding([int][OcrSmokeNative]::GetACP(),
        [Text.EncoderExceptionFallback]::new(), [Text.DecoderExceptionFallback]::new())
    $bytes = $encoding.GetBytes($Text + [char]0)
    $pointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
    [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $pointer, $bytes.Length)
    $pointer
}

$runtime = Join-Path $PSScriptRoot 'runtime\x64'
$leptonica = [OcrSmokeNative]::LoadLibraryExW((Join-Path $runtime 'leptonica-1.82.0.dll'), [IntPtr]::Zero, 0x1100)
if ($leptonica -eq [IntPtr]::Zero) { throw "Cannot load bundled Leptonica: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
$library = [OcrSmokeNative]::LoadLibraryExW((Join-Path $runtime 'tesseract50.dll'), [IntPtr]::Zero, 0x1100)
if ($library -eq [IntPtr]::Zero) { throw "Cannot load bundled Tesseract: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
$create = Get-OcrFunction $library 'TessBaseAPICreate' ([OcrSmokeNative+Create])
$delete = Get-OcrFunction $library 'TessBaseAPIDelete' ([OcrSmokeNative+Delete])
$init = Get-OcrFunction $library 'TessBaseAPIInit2' ([OcrSmokeNative+Init])
$setImage = Get-OcrFunction $library 'TessBaseAPISetImage' ([OcrSmokeNative+SetImage])
$getText = Get-OcrFunction $library 'TessBaseAPIGetUTF8Text' ([OcrSmokeNative+GetText])
$deleteText = Get-OcrFunction $library 'TessDeleteText' ([OcrSmokeNative+DeleteText])

$bitmap = [Drawing.Bitmap]::new(1800, 320, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$font = [Drawing.Font]::new('Microsoft YaHei', 48)
$graphics.Clear([Drawing.Color]::White)
$graphics.DrawString('动量守恒 Momentum is conserved', $font, [Drawing.Brushes]::Black, 24, 90)
$font.Dispose()
$graphics.Dispose()
$pixels = $bitmap.LockBits([Drawing.Rectangle]::new(0, 0, $bitmap.Width, $bitmap.Height),
    [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
$api = $create.Invoke()
$dataPath = New-NativeString (Join-Path $ProjectDirectory 'assets\ocr')
$language = New-NativeString 'chi_sim+eng'
try {
    $status = $init.Invoke($api, $dataPath, $language, 1)
    if ($status -ne 0) { throw "Tesseract init failed with code $status" }
    $setImage.Invoke($api, $pixels.Scan0, $bitmap.Width, $bitmap.Height, 3, $pixels.Stride)
    $textPointer = $getText.Invoke($api)
    try {
        $recognized = [Runtime.InteropServices.Marshal]::PtrToStringUTF8($textPointer)
        Write-Output $recognized.Trim()
        if ($recognized -notmatch 'Momentum' -or $recognized -notmatch '守恒') {
            throw 'The generated bilingual smoke sample did not match expected text.'
        }
        Write-Output 'PASS: bundled x64 OCR recognizes a generated bilingual image using a Unicode project path.'
    } finally { $deleteText.Invoke($textPointer) }
} finally {
    [Runtime.InteropServices.Marshal]::FreeHGlobal($dataPath)
    [Runtime.InteropServices.Marshal]::FreeHGlobal($language)
    $delete.Invoke($api)
    $bitmap.UnlockBits($pixels)
    $bitmap.Dispose()
    [void][OcrSmokeNative]::FreeLibrary($library)
    [void][OcrSmokeNative]::FreeLibrary($leptonica)
}
