Import-Module -Name Az.Network
Import-Module -Name Az.Resources

function Complete-PolicyComplianceScan {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSResourceGroup]$ResourceGroup
    )

    $job = Start-AzPolicyComplianceScan -ResourceGroupName $ResourceGroup.ResourceGroupName -AsJob 
    $job | Wait-Job
}

function Complete-PolicyRemediation {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSResourceGroup]$ResourceGroup,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PolicyName
    )
    
    $scope = "/subscriptions/$((Get-AzContext).Subscription.Id)"
    $policyAssignmentId = (Get-AzPolicyAssignment -Scope $scope
        | Select-Object -Property PolicyAssignmentId -ExpandProperty Properties 
        | Where-Object { $_.DisplayName -eq $PolicyName } 
        | Select-Object -Property PolicyAssignmentId -First 1
    ).PolicyAssignmentId
    
    if ($null -eq $policyAssignmentId) {
        throw "Policy assignment was not found for policy '$($PolicyName)' at scope '$($scope)'."
    }

    $job = Start-AzPolicyRemediation `
        -ResourceGroupName $ResourceGroup.ResourceGroupName `
        -PolicyAssignmentId $policyAssignmentId `
        -Name $ResourceGroup.ResourceGroupName `
        -ResourceDiscoveryMode ReEvaluateCompliance `
        -LocationFilter $ResourceGroup.Location `
        -AsJob
    $remediation = $job | Wait-Job | Receive-Job
    
    # When remediation is not successful
    if ($remediation.ProvisioningState -ne "Succeeded") {
        throw "Policy '$($PolicyName)' could not remediate resource group '$($ResourceGroup.ResourceGroupName)'."
    }
}

function Get-PolicyComplianceState {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSResourceId]$Resource,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PolicyName
    )

    $policyDefinition = Get-AzPolicyDefinition | Where-Object { $_.Properties.DisplayName -eq $PolicyName }
    
    if ($null -eq $policyDefinition) {
        $scope = "/subscriptions/$((Get-AzContext).Subscription.Id)"
        throw "Policy definition '$($PolicyName)' was not found at scope '$($scope)'."
    }

    $compliant = (
        Get-AzPolicyState -PolicyDefinitionName $policyDefinition.Name 
        | Where-Object { $_.ResourceId -eq $Resource.Id } 
        | Select-Object -Property ComplianceState
    ).ComplianceState -eq "Compliant"

    return $compliant
}

function Get-RouteNextHopVirtualAppliance {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSRouteTable]$RouteTable
    )
    
    $addressPrefix = "0.0.0.0/0"
    $nextHopType = "VirtualAppliance"
    $nextHopIpAddress > $null
    switch ($RouteTable.Location) {
        "northeurope" { $nextHopIpAddress = "10.0.0.23"; break }
        "westeurope" { $nextHopIpAddress = "10.1.0.23"; break }
        default { throw "Location '$($RouteTable.Location)' not handled." }
    }

    $route = $RouteTable.Routes | Where-Object { 
        ($_.AddressPrefix -eq $addressPrefix) -and
        ($_.NextHopType -eq $nextHopType) -and
        ($_.NextHopIpAddress -eq $nextHopIpAddress)
    } | Select-Object -First 1 # Address prefixes are unique within a route table

    return $route
}

function Remove-RouteNextHopVirtualAppliance {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSRouteTable]$RouteTable
    )

    $route = $RouteTable | Get-RouteNextHopVirtualAppliance 
    if ($null -eq $route) {
        throw "Route pointing to the virtual appliance does not exist in route table '$($RouteTable.Name)'."
    }    

    # Remove-AzRouteConfig will issue a PUT request for routeTables and hence the route will be appended by policy.
    # In order to remove the route, directly call the REST API by issuing a DELETE request for route.
    $httpResponse = Invoke-AzRestMethod `
        -ResourceGroupName $RouteTable.ResourceGroupName `
        -ResourceProviderName "Microsoft.Network" `
        -ResourceType @("routeTables", "routes") `
        -Name @($RouteTable.Name, $route.Name) `
        -ApiVersion "2020-05-01" `
        -Method "DELETE"

    # When HTTP request is not successful
    if (-not ($httpResponse.StatusCode -in 200..299)) {
        throw "Route '$($route.Name)' could not be removed from route table '$($RouteTable.Name)'."
    }

    # Defensive programming: Reloading route table to check if route has been removed
    $RouteTable = Get-AzRouteTable -ResourceGroupName $RouteTable.ResourceGroupName -Name $RouteTable.Name
    if ($RouteTable | Test-RouteNextHopVirtualAppliance) {
        throw "Route pointing to the virtual appliance still exists in route table '$($RouteTable.Name)'."
    }

    return $RouteTable
}

function Test-RouteNextHopVirtualAppliance {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSRouteTable]$RouteTable
    )
    
    $route = $RouteTable | Get-RouteNextHopVirtualAppliance 

    return $null -ne $route
}