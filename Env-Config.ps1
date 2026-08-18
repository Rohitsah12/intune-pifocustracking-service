# Env-Config.ps1
#
# Single source of truth for every environment-dependent value referenced by
# install.ps1, detect.ps1, uninstall.ps1, Build-Package.ps1, and diagnose.ps1.
# Mirrors the C++ Env.h header in WindowService/ and HelperService/.
#
# Usage from any other script:
#   . (Join-Path $PSScriptRoot 'Env-Config.ps1')
#   $cfg = Get-PiFocusEnv -Env $Env      # $Env is 'prod' or 'stage'
#   ...then reference $cfg.ServiceName / $cfg.InstallDir / etc.

function Get-PiFocusEnv {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('prod','stage')]
        [string]$Env
    )

    if ($Env -eq 'stage') {
        return @{
            EnvName             = 'stage'
            EnvSuffix           = 'Stage'
            ServiceName         = 'PiFocusWindowServiceStage'
            ServiceDisplayName  = 'PiFocus Window Service (Staging)'
            ServiceDescription  = 'PiFocus background tracking service (Staging)'
            InstallDir          = 'C:\Program Files\PiFocus\AgentStage'
            ProgramDataDir      = 'C:\ProgramData\PiFocusStage'
            ProgramMonitorDir   = 'C:\ProgramData\ProgramMonitorStage'
            LogDir              = 'C:\ProgramData\PiFocusStage\Logs'
            HklmRoot            = 'HKLM:\SOFTWARE\PiFocusStage'
            HklmRootBackslash   = 'SOFTWARE\PiFocusStage'
            HkcuHelperSubkey    = 'Software\PiFocusStage\Helper'
            DeviceTokenValueName= 'DeviceApiKey'
            PipeName            = '\\.\pipe\PiFocusIPCStage'
            GlobalPauseEvent    = 'Global\PiFocusPauseEventStage'
            GlobalModeEvent     = 'Global\PiFocusModeChangedStage'
            GlobalHelperMutex   = 'Global\PiFocusHelperSingletonStage'
            ApiHost             = 'stage-api.penpencil.co'
            WsHost              = 'stage-pi-os-backend.penpencil.co'
        }
    }

    return @{
        EnvName             = 'prod'
        EnvSuffix           = ''
        ServiceName         = 'PiFocusWindowService'
        ServiceDisplayName  = 'PiFocus Window Service'
        ServiceDescription  = 'PiFocus background tracking service'
        InstallDir          = 'C:\Program Files\PiFocus\Agent'
        ProgramDataDir      = 'C:\ProgramData\PiFocus'
        ProgramMonitorDir   = 'C:\ProgramData\ProgramMonitor'
        LogDir              = 'C:\ProgramData\PiFocus\Logs'
        HklmRoot            = 'HKLM:\SOFTWARE\PiFocus'
        HklmRootBackslash   = 'SOFTWARE\PiFocus'
        HkcuHelperSubkey    = 'Software\PiFocus\Helper'
        DeviceTokenValueName= 'DeviceApiKey'
        PipeName            = '\\.\pipe\PiFocusIPC'
        GlobalPauseEvent    = 'Global\PiFocusPauseEvent'
        GlobalModeEvent     = 'Global\PiFocusModeChanged'
        GlobalHelperMutex   = 'Global\PiFocusHelperSingleton'
        ApiHost             = 'api.penpencil.co'
        WsHost              = 'pi-os-backend.penpencil.co'
    }
}
