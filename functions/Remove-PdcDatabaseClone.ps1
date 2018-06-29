function Remove-PdcDatabaseClone {
<#
.SYNOPSIS
    Remove-PdcDatabaseClone removes one or more clones from a host

.DESCRIPTION
    Remove-PdcDatabaseClone is able to remove one or more clones from a host.
    The command looks up all the records dor a particular hostname.
    It will remove the database from the database server and all related files.

    The filter parameters Database and ExcludeDatabase work like wildcards.
    There is no need to include the asterisk (*). See the examples for more details

.PARAMETER HostName
    The hostname to filter on


.PARAMETER SqlCredential
    Allows you to login to servers using SQL Logins as opposed to Windows Auth/Integrated/Trusted. To use:

    $scred = Get-Credential, then pass $scred object to the -SqlCredential parameter.

    Windows Authentication will be used if SqlCredential is not specified. SQL Server does not accept Windows credentials being passed as credentials.
    To connect as a different Windows user, run PowerShell as that user.

.PARAMETER Credential
    Allows you to login to systems using a credential. To use:

    $scred = Get-Credential, then pass $scred object to the -Credential parameter.

.PARAMETER Database
    Allows to filter to include specific databases

.PARAMETER ExcludeDatabase
    Allows to filter to exclude specific databases

.NOTES
    Author: Sander Stad (@sqlstad, sqlstad.nl)

    Website: https://psdatabaseclone.io
    Copyright: (C) Sander Stad, sander@sqlstad.nl
    License: MIT https://opensource.org/licenses/MIT

.LINK
    https://psdatabaseclone.io/

.EXAMPLE
    Remove-PdcDatabaseClone -HostName Host1 -Database Clone1

    Removes the clones that are registered at Host1 and have the text "Clone1"

.EXAMPLE
    Remove-PdcDatabaseClone -HostName Host1, Host2, Host3 -Database Clone

    Removes the clones that are registered at multiple hosts and have the text "Clone"

.EXAMPLE
    Remove-PdcDatabaseClone -HostName Host1

    Removes all clones from Host1

#>
    [CmdLetBinding()]

    param(
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$HostName,

        [System.Management.Automation.PSCredential]
        $SqlCredential,

        [System.Management.Automation.PSCredential]
        $Credential,

        [string[]]$Database,

        [string[]]$ExcludeDatabase,

        [switch]$All

    )

    begin {
        Write-PSFMessage -Message "Started removing database clones" -Level Verbose

        # Test the module database setup
        $result = Test-PdcConfiguration -SqlInstance $ecDatabaseServer -SqlCredential $SqlCredential -Database $ecDatabaseName

        if(-not $result.Check){
            Stop-PSFFunction -Message $result.Message -Target $result -Continue
            return
        }
    }

    process {
        # Test if there are any errors
        if (Test-PSFFunctionInterrupt) { return }

        # initialize the result variable
        $result = $null

        # Loop through each of the host names
        foreach ($hst in $HostName) {

            # Check the host parameter
            if (-not $hst) {
                Stop-PSFFunction -Message "The input '$hst' for the parameter HostName was not valid" -Target $hst -Continue
            }

            # Set the computer variable
            $computer = [psfcomputer]$hst

            $query = "
                SELECT h.HostName,
                    c.CloneLocation,
                    c.AccessPath,
                    c.SqlInstance,
                    c.DatabaseName,
                    c.IsEnabled
                FROM dbo.Clone AS c
                INNER JOIN dbo.Host AS h ON h.HostID = c.HostID
                WHERE h.HostName LIKE ( '%$($computer.ComputerName)%' ) "

            try {
                $results += Invoke-DbaSqlQuery -SqlInstance $ecDatabaseServer -Database $ecDatabaseName -Query $query
            }
            catch {
                Stop-PSFFunction -Message "Couldn't retrieve clone records for host $hst" -Target $hst -Continue
            }

        } # End loop host name

        # Check the database parameters
        if ($Database) {
            Write-PSFMessage -Message "Filtering included databases for host $($computer.ComputerName)" -Level Verbose
            $results = $results | Where-Object {$_.DatabaseName -match $Database}
        }

        if ($ExcludeDatabase) {
            Write-PSFMessage -Message "Filtering excluded databases for host $($computer.ComputerName)" -Level Verbose
            $results = $results | Where-Object {$_.DatabaseName -notmatch $ExcludeDatabase}
        }


        # Loop through each of the results
        foreach ($result in $results) {

            # Connect to the instance
            Write-PSFMessage -Message "Attempting to connect to easy clone database server $($result.SqlInstance).." -Level Verbose
            try {
                $server = Connect-DbaInstance -SqlInstance $result.SqlInstance -SqlCredential $SqlCredential
            }
            catch {
                Stop-PSFFunction -Message "Could not connect to Sql Server instance $server" -ErrorRecord $_ -Target $server -Continue
            }

            # Remove the database
            try {
                Write-PSFMessage -Message "Removing database $($result.DatabaseName) from $($result.SqlInstance)" -Level Verbose

                $null = Remove-DbaDatabase -SqlInstance $result.SqlInstance -SqlCredential $SqlCredential -Database $result.DatabaseName -Confirm:$false
            }
            catch {
                Stop-PSFFunction -Message "Could not remove database $($result.DatabaseName) from $server" -ErrorRecord $_ -Target $server -Continue
            }

            # Dismounting the vhd
            try {
                Write-PSFMessage -Message "Dismounting disk $($result.DatabaseName) from $($result.SqlInstance)" -Level Verbose
                Dismount-VHD -Path $result.CloneLocation
            }
            catch {
                Stop-PSFFunction -Message "Could not dismount vhd $($result.CloneLocation)" -ErrorRecord $_ -Target $result -Continue
            }

            # Remove clone file and related access path
            try {
                Write-PSFMessage -Message "Removing vhd access path" -Level Verbose
                Remove-Item -Path $result.AccessPath -Credential $Credential -Force | Out-Null

                Write-PSFMessage -Message "Removing vhd" -Level Verbose
                Remove-Item -Path $result.CloneLocation -Credential $Credential -Force | Out-Null
            }
            catch {
                Stop-PSFFunction -Message "Could not remove clone files" -ErrorRecord $_ -Target $result -Continue
            }

            # Removing records from database
            try {
                $query = "
                    DELETE c
                    FROM dbo.Clone AS c
                        INNER JOIN dbo.Host AS h
                            ON h.HostID = h.HostID
                    WHERE h.HostName = '$($result.HostName)'
                        AND c.CloneLocation = '$($result.CloneLocation)';
                "

                Invoke-DbaSqlQuery -SqlInstance $ecDatabaseServer -Database $ecDatabaseName -Query $query
            }
            catch {
                Stop-PSFFunction -Message "Could not remove clone record from database" -ErrorRecord $_ -Target $result -Continue
            }
        }

    } # End process

    end {
        # Test if there are any errors
        if (Test-PSFFunctionInterrupt) { return }

        Write-PSFMessage -Message "Finished removing database clone(s)" -Level Verbose
    }
}