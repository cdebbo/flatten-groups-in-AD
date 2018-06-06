<#
Create-FlatGroups creates a single "flat" group of users from a set of source hierarchical groups. The tool
can also sync that flat group as the source groups change.

For example, given the following source group called 'all-staff', create a single target group called 'flat-all-staff',
all-staff (members):
  teachers (members):
    school1 (members):
      teacher-jane
      teacher-jack
    school2 (members):
      teacher-phil
      teacher-mary
  administrators (members):
    boss-frank
    boss-albert
    boss-rachael

flat-all-staff (members):
  teacher-jane
  teacher-jack
  teacher-phil
  teacher-mary
  boss-frank
  boss-albert
  boss-rachael

The tool doesn't modify the source groups.

There are systemwide threasholds. The tool will warn and not run if there are more than 10 users removed from 
a target group.
The tool will warn and not run if there are more than 60 users added to a target group. These can be changed.

Set appropriate levels or add an override flag.

The tool also has a validate option where it will simply report the changes but not perform them.

The tool can process multiple target groups in a single run.

Output is logged to ./logs/*log files. See code for details on PS-Log.

At our board these groups are used by LDAP clients to learn group membership for the purposes of
of privilege authorization.

Sample JSON file:
{
  "comment": "create flat lists (fl_) from the list of source groups. Only users in the leaves of these one level fl_ groups",
  "threashold": {
    "max_remove": 10,
    "max_add": 60
  },
  "groups": [
    {
      "active": 1,                     <---- 1 = perform this rule, 0 = ignore
      "target": "fl_workorder_users",  <---- target group. skips this rule if group doesn't exist.
      "sources": [                     <---- list of source groups for tool to flatten
        "principals",
        "it support",
        "boardoffice",
        "custodial"
      ]
    },
    {
      "active": 0,
      "target": "fl_all_staff",
      "sources": [
        "all permanent staff"
      ]
    }
  ]
}

#>

# $validate:$true for validation
param($settingsFile = "groups.json", $validate = $false);

Import-Module PS-Log.psm1

$scriptInfo = get-scriptInfo
$logfilename = Join-Path (Join-Path $scriptInfo.Path "logs") $($scriptInfo.Name + '.log')

# manage your log files before you start writing to them.
Switch-LogFile -Name $logFileName
$gplog = New-LogFile $scriptInfo.Name $logFileName

$gplog.WritePSInfo("ScriptName = $($scriptInfo.Name.ToString()) Starting")

$thresholdcrossed = "";

try {
    $settings = $(get-content $settingsFile -raw; ) | ConvertFrom-Json
}
catch {
    $gplog.WritePSWarning("Can't load the group file - Exiting") 
    exit;
}

foreach ($g in $settings.groups) {
    if ($g.active -ne 1) {
        $gplog.WritePSInfo("Skipping inactive target group $($g.target)")
        continue;
    }
    $gplog.WritePSInfo("At $($g.target)")
    $susers = @();
    foreach ($s in $g.sources) {
        $gplog.WritePSInfo("loading source group '$s'")
        $ado = Get-ADObject -filter 'name -like $s';
        if ($ado -ne $null -and $ado.getType().Name -eq "ADObject") {
            switch ($ado.ObjectClass) {
                "group" {
                    $m = Get-ADGroupMember $ado -Recursive;
                    $m | where-object { $_.objectClass -eq "user"} |  ForEach-Object { $susers += $_}
                }
                "user" { $susers += $ado}
            }
        }
    }
    $susers = $susers | Sort-Object distinguishedName
    # now compare to existing target group
    try {
        $tusers = Get-ADGroupMember $g.target | Sort-Object distinguishedName;
    }
    catch {
        $gplog.WritePSInfo("Error finding group $($g.target). Skipping")
        continue;
    }
    if ($tusers.length -eq 0) {
      if (! $validate) {
        Add-ADGroupMember $g.target -Members $susers
      }
      $gplog.WritePSInfo("Found empty target group. Added $($susers.count) members")
    }
    else {
        $c = compare-object -ReferenceObject $tusers -DifferenceObject $susers -Property distinguishedName
        $add = @();
        $remove = @();
        foreach ($i in $c) {
            switch ($i.SideIndicator) { 
                "=>" { $add += $c.distinguishedName; }
                "<=" { $remove += $c.distinguishedName; }
            }
        }
        if ($add.length -gt 0) {
          if ($settings.threashold.max_add -ge $add.length) {
            if (! $validate) {
              Add-ADGroupMember $g.target -Members $add -Confirm:$false
            }
            $gplog.WritePSInfo("Added: " + $($add -join(",")));
            $gplog.WritePSInfo("Added $($add.count) members");
          } else {
            $thresholdcrossed += "Add: " + $g.target + " (" + $add.count + ")`n";
            $gplog.WritePSWarning(("Exceeded Add-user {0} threshold {1}. Check thresholds or maybe group loading error." -f $add.length, $settings.threashold.max_add));
          }
        }
        if ($remove.length -gt 0) {
          if ($settings.threashold.max_remove -ge $remove.length) {
            if (! $validate) {
              Remove-ADGroupMember $g.target -Members $remove -Confirm:$false
            }
            $gplog.WritePSInfo("Removed: " + $($remove -join(",")));
            $gplog.WritePSInfo("Removed $($remove.count) members");
          } else {
            $thresholdcrossed += "Remove: " + $g.target + " (" + $remove.count + ")`n";
            $gplog.WritePSWarning("Exceeded Remove-user threshold. Check thresholds or maybe group loading error.");
          }
        }
    }
}

$gplog.WritePSInfo("ScriptName = $($scriptInfo.Name.ToString()) Finishing")

if ($thresholdcrossed.length -gt 0) {
  $body = "Create Flat Files on \\server`n$($thresholdcrossed)"
  Send-MailMessage -To "someone@somewhere" -Subject "Create Flat Files - Threshold Crossed" -SmtpServer my-mx-server -from "someone@somewhere" -body $body
}
