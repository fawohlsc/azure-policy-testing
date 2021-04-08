Describe "Testing policy 'Audit-Route-NextHopVirtualAppliance'" -Tag "audit-route-nexthopvirtualappliance" {
    BeforeAll {
        # Import modules.
        Import-Module -Name Az.Network
        Import-Module -Name Az.Resources

        # Import utils by dot sourcing.
        $utils = [IO.Path]::Combine((Split-Path $PSScriptRoot -Parent), "utils")
        . "$($utils)/TestContext.ps1"
        . "$($utils)/Rest.Utils.ps1"
        . "$($utils)/Policy.Utils.ps1"
        . "$($utils)/Test.Utils.ps1"
        . "$($utils)/RouteTable.Utils.ps1"

        # Before all tests, initialize the test context and create an unique policy definition at subscription scope.
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
            # Create an unique resource group, assign the policy to the resource group and execute the test.
            # After executing the test, the policy assignment and resource group will be deleted.
            AzPolicyTest -TestContext $TestContext {
                # Create compliant route table with route 0.0.0.0/0 pointing to the virtual appliance.
                $route = New-AzRouteConfig `
                    -Name "default" `
                    -AddressPrefix "0.0.0.0/0" `
                    -NextHopType "VirtualAppliance" `
                    -NextHopIpAddress $TestContext.PolicyParameterObject.routeTableSettings.northeurope.virtualApplianceIpAddress
                                
                $routeTable = New-AzRouteTable `
                    -Name "route-table" `
                    -ResourceGroupName $TestContext.ResourceGroup.ResourceGroupName `
                    -Location $TestContext.ResourceGroup.Location `
                    -Route $Route

                # Trigger compliance scan for resource group and wait for completion.
                Complete-PolicyComplianceScan -TestContext $TestContext 

                # Verify that route table is compliant.
                Get-PolicyComplianceState `
                    -TestContext $TestContext `
                    -ResourceId $routeTable.Id
                | Should -BeTrue
            }
        }

        It "Should mark route table as incompliant without route 0.0.0.0/0 pointing to virtual appliance." -Tag "audit-route-nexthopvirtualappliance-incompliant" {
            # Create an unique resource group, assign the policy to the resource group and execute the test.
            # After executing the test, the policy assignment and resource group will be deleted.
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
                    -TestContext $TestContext `
                    -ResourceId $routeTable.Id
                | Should -BeFalse
            }
        }
    }

    AfterAll {
        # After all tests, delete the unique policy definition at subscription scope.
        Clear-AzPolicyTest -TestContext $TestContext
    }
}
