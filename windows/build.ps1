# Squidpal for Windows – build script (PowerShell).
#
#   .\build.ps1 test        run the redaction self-test (needs the .NET 8 SDK)
#   .\build.ps1 run         build and run the tray app for local testing
#   .\build.ps1 dist        publish single-file self-contained .exe for x64 + arm64,
#                           and zip each with the tester guide
#
# The published .exe is self-contained, so the tester needs no .NET install.
param([string]$Mode = "run")

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$sln = "src"

function Check-Dotnet {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Write-Error "dotnet hittades inte. Installera .NET 8 SDK från https://dotnet.microsoft.com/download/dotnet/8.0"
    }
}

switch ($Mode) {
    "test" {
        Check-Dotnet
        dotnet run --project "$sln/DayLog.SelfTest" -c Release -- "$PSScriptRoot/../shared/redaction-fixtures.json"
    }
    "run" {
        Check-Dotnet
        dotnet run --project "$sln/DayLog.Win" -c Debug
    }
    "dist" {
        Check-Dotnet
        $out = Join-Path $PSScriptRoot "dist"
        Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $out | Out-Null
        $ver = ([xml](Get-Content "$sln/DayLog.Win/DayLog.Win.csproj")).Project.PropertyGroup.Version
        foreach ($rid in @("win-x64", "win-arm64")) {
            Write-Host "-> publishing $rid"
            dotnet publish "$sln/DayLog.Win" -c Release -r $rid --self-contained true `
                -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
                -o "$out/$rid"
            $stage = "$out/Squidpal-$ver-$rid"
            New-Item -ItemType Directory -Path $stage | Out-Null
            Copy-Item "$out/$rid/Squidpal.exe" $stage
            Copy-Item "$PSScriptRoot/READ-ME-FIRST.txt" "$stage/READ-ME-FIRST.txt"
            Compress-Archive -Path "$stage/*" -DestinationPath "$out/Squidpal-$ver-$rid.zip" -Force
            Write-Host "Klart: $out/Squidpal-$ver-$rid.zip"
        }
        Write-Host ""
        Write-Host "Skicka win-x64-zippen till de flesta testare. win-arm64 är för Snapdragon/ARM-datorer."
        Write-Host "Osignerad: SmartScreen varnar en gång (see 'READ-ME-FIRST.txt')."
    }
    default { Write-Error "Okänt läge: $Mode (använd test, run eller dist)" }
}
