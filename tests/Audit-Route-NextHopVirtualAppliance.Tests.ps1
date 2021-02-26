Import-Module -Name Az.Network
Import-Module -Name Az.Resources
Import-Module "$($PSScriptRoot)/../utils/Policy.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/../utils/Rest.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/../utils/RouteTable.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/../utils/Test.Utils.psm1" -Force

Describe "Testing policy 'Audit-Route-NextHopVirtualAppliance'" -Tag "audit-route-nexthopvirtualappliance" {
    BeforeAll {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
        $TestContext = Initialize-AzPolicyTest -PolicyParameterObject @{
            "routeTableSettings" = @{
                "northeurope" = @{
                    "virtualApplianceIpAddress" = "10.0.0.23"
                }; 
                "disabled"    = @{
                    "virtualApplianceIpAddress" = ""
                }
            }
        }
    }
    
    Context "When auditing route tables" {
        It "Should mark route table as compliant with route 0.0.0.0/0 pointing to virtual appliance." -Tag "audit-route-nexthopvirtualappliance-compliant" {
            AzPolicyTest -TestContext $TestContext {
                # Create compliant route table with route 0.0.0.0/0 pointing to the virtual appliance.
                $nextHopIpAddress = $TestContext.PolicyParameterObject.routeTableSettings.northeurope.virtualApplianceIpAddress
                
                $route = New-AzRouteConfig `
                    -Name "default" `
                    -AddressPrefix "0.0.0.0/0" `
                    -NextHopType "VirtualAppliance" `
                    -NextHopIpAddress $nextHopIpAddress
                                
                $routeTable = New-AzRouteTable `
                    -Name "route-table" `
                    -ResourceGroupName $TestContext.ResourceGroup.ResourceGroupName `
                    -Location $TestContext.ResourceGroup.Location `
                    -Route $Route

                # Trigger compliance scan for resource group and wait for completion.
                Complete-PolicyComplianceScan -TestContext $TestContext 

                # Verify that route table is compliant.
                Get-PolicyComplianceState `
                    -Resource $routeTable `
                    -TestContext $TestContext
                | Should -BeTrue
            }
        }

        It "Should mark route table as incompliant without route 0.0.0.0/0 pointing to virtual appliance." -Tag "audit-route-nexthopvirtualappliance-incompliant" {
            AzPolicyTest -TestContext $TestContext {
                # Create incompliant route table without route 0.0.0.0/0 pointing to the virtual appliance.
                $routeTable = New-AzRouteTable `
                    -Name "route-table" `
                    -ResourceGroupName $TestContext.ResourceGroup.ResourceGroupName `
                    -Location $TestContext.ResourceGroup.Location `
                    -Route $Route

                # Trigger compliance scan for resource group and wait for completion.
                Complete-PolicyComplianceScan -TestContext $TestContext 

                # Verify that route table is incompliant.
                Get-PolicyComplianceState `
                    -Resource $routeTable `
                    -TestContext $TestContext
                | Should -BeFalse
            }
        }
    }

    AfterAll {
        Clear-AzPolicyTest -TestContext $TestContext
    }
}
