#title: AzureArc_VMs_Extensions_Upgrade
#author: Patrycja Stopka patrycja.stopka@soprasteria.com
#date: 25.03.2026
#version: 1.0

param (
    [string]$SubscriptionId = "" #put the id of your subscription
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Update-ArcExtension {
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Extensions,
        [Parameter(Mandatory = $true)]
        [string]$ExtensionName,
        [Parameter(Mandatory = $true)]
        [string]$TargetVersion,
        [Parameter(Mandatory = $true)]
        [string]$MachineName,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId
    )

    $extension = $Extensions | Where-Object { $_.Name -eq $ExtensionName } | Select-Object -First 1
    if (-not $extension) {
        Write-Output "    $ExtensionName not installed."
        return
    }

    if (-not $extension.Location -or -not $extension.Publisher -or -not $extension.MachineExtensionType) {
        throw "Unable to determine location, publisher, or extension type for $ExtensionName."
    }

    Write-Output "    Updating $ExtensionName from $($extension.TypeHandlerVersion) to $TargetVersion..."

    $extension.TypeHandlerVersion = $TargetVersion

    Set-AzConnectedMachineExtension `
        -MachineName $MachineName `
        -Name $ExtensionName `
        -ResourceGroupName $ResourceGroupName `
        -SubscriptionId $SubscriptionId `
        -ExtensionParameter $extension | Out-Null

    $maxAttempts = 12
    $sleepSeconds = 10
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $current = Get-AzConnectedMachineExtension `
            -MachineName $MachineName `
            -ResourceGroupName $ResourceGroupName `
            -SubscriptionId $SubscriptionId `
            -Name $ExtensionName

        if ($current.TypeHandlerVersion -eq $TargetVersion) {
            Write-Output "      $ExtensionName successfully updated to $TargetVersion."
            return
        }

        Write-Output "      $ExtensionName currently at $($current.TypeHandlerVersion). Waiting... (attempt $attempt/$maxAttempts)"
        Start-Sleep -Seconds $sleepSeconds
    }

    throw "$ExtensionName did not reach target version $TargetVersion within $($maxAttempts * $sleepSeconds) seconds."
}

try {
    Connect-AzAccount -Subscription $SubscriptionId | Out-Null
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

    Write-Output "Starting Azure Arc Extension Upgrade - ALL MACHINES IN SUBSCRIPTION..."
    
    $patchExtensionVersion = "1.5.80"
    $osUpdateExtensionVersion = "1.0.35.0"

    $updatePlan = @(
        @{ Name = "WindowsOsUpdateExtension"; TargetVersion = $osUpdateExtensionVersion },
        @{ Name = "WindowsPatchExtension"; TargetVersion = $patchExtensionVersion }
    )

    # Pobierz WSZYSTKIE Arc machines (bez filtra statusu)
    $allMachines = Get-AzConnectedMachine -SubscriptionId $SubscriptionId | Sort-Object ResourceGroupName, Name
    
    if (-not $allMachines) {
        Write-Warning "No Azure Arc machines found in subscription $SubscriptionId."
        exit
    }

    Write-Output "Found $($allMachines.Count) total Arc machines."

    $onlineCount = 0
    $totalMachines = 0
    $processed = 0
    
    foreach ($machine in $allMachines) {
        $processed++
        $MachineName = $machine.Name
        $ResourceGroupName = $machine.ResourceGroupName
        $status = $machine.Status  # Status z Get-AzConnectedMachine
        
        Write-Output "`n[$processed/$($allMachines.Count)] $MachineName (RG: $ResourceGroupName) - Status: $status"

        # POMIŃ OFFLINE maszyny
        if ($status -ne "Connected") {
            Write-Warning "  -> SKIPPING (Status: $status)"
            continue
        }

        $onlineCount++
        Write-Output "  -> ONLINE - Processing extensions..."

        try {
            $extensions = Get-AzConnectedMachineExtension `
                -MachineName $MachineName `
                -ResourceGroupName $ResourceGroupName `
                -SubscriptionId $SubscriptionId

            $updateFailures = @()
            foreach ($item in $updatePlan) {
                try {
                    Update-ArcExtension `
                        -Extensions $extensions `
                        -ExtensionName $item.Name `
                        -TargetVersion $item.TargetVersion `
                        -MachineName $MachineName `
                        -ResourceGroupName $ResourceGroupName `
                        -SubscriptionId $SubscriptionId
                }
                catch {
                    $message = "  $($item.Name) update failed: $($_.Exception.Message)"
                    Write-Warning $message
                    $updateFailures += $message
                }
            }
            
            if ($updateFailures.Count -gt 0) {
                Write-Warning "  Some updates failed on $MachineName"
            }
        }
        catch {
            Write-Warning "  Failed to process extensions: $($_.Exception.Message)"
        }
    }

    Write-Output "`nScript finished. Processed $onlineCount ONLINE / $processed total Arc machines."
}
catch {
    Write-Error "Script failed: $($_.Exception.Message)"
    throw
}
