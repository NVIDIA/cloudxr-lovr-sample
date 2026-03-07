# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: MIT
#
# Opens Windows Firewall inbound rules required by the CloudXR streaming server,
# scoped to lovr.exe so no other process can use these ports through the rule.
# Must be run as Administrator.
#
# UDP: 47998, 47999, 48000, 48002, 48005  (CloudXR streaming)
# TCP: 48010, 49100                        (CloudXR control / signaling)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\open_firewall_ports.ps1 [-ExePath path\to\lovr.exe]

#Requires -RunAsAdministrator

param(
    [string]$ExePath = ""
)

$ruleName = "CloudXR Server"

$udpPorts = @(47998, 47999, 48000, 48002, 48005)
$tcpPorts = @(48010, 49100)

# Resolve lovr.exe: use explicit arg, then search build/ for Release then Debug.
if ($ExePath -eq "") {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $candidates = @(
        Join-Path $repoRoot "build\Release\lovr.exe"
        Join-Path $repoRoot "build\Debug\lovr.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $ExePath = $c; break }
    }
}

if ($ExePath -eq "" -or -not (Test-Path $ExePath)) {
    Write-Error "Could not find lovr.exe. Pass -ExePath <path> explicitly."
    exit 1
}

$ExePath = (Resolve-Path $ExePath).Path
Write-Host "Scoping rules to: $ExePath"

function Set-FirewallRule {
    param(
        [string]$Name,
        [string]$Protocol,
        [int[]]$Ports,
        [string]$Program
    )
    $portList = $Ports -join ","
    $fullName = "$Name ($Protocol $portList)"

    # Remove any existing rule with this name so we always end up with a clean state.
    Remove-NetFirewallRule -DisplayName $fullName -ErrorAction SilentlyContinue

    New-NetFirewallRule `
        -DisplayName  $fullName `
        -Direction    Inbound `
        -Protocol     $Protocol `
        -LocalPort    $Ports `
        -Program      $Program `
        -Action       Allow `
        -Profile      Any `
        -Description  "CloudXR server inbound $Protocol ports" | Out-Null

    Write-Host "  Added: $fullName"
}

Write-Host "Configuring Windows Firewall rules for CloudXR server..."
Set-FirewallRule -Name $ruleName -Protocol UDP -Ports $udpPorts -Program $ExePath
Set-FirewallRule -Name $ruleName -Protocol TCP -Ports $tcpPorts -Program $ExePath
Write-Host "Done."
