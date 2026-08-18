'use strict';

// Environment constants, mirroring WindowService/Env.h, HelperService/Env.h,
// Env-Config.ps1 and the Electron app's src/main/env.ts.
//
// Select with:  PIFOCUS_ENV=stage   (default: prod)
//
// Getting this wrong is silent: a prod-named event/pipe/registry key simply
// does not exist on a stage machine, so every check would report "unknown"
// rather than failing loudly. assertEnvSane() below turns that into an error.

const rawEnv = (process.env.PIFOCUS_ENV || 'prod').toLowerCase();
const isStage = rawEnv === 'stage' || rawEnv === 'staging';

const ENV = isStage ? 'stage' : 'prod';

const PIPE_NAME        = isStage ? '\\\\.\\pipe\\PiFocusIPCStage'    : '\\\\.\\pipe\\PiFocusIPC';
const PAUSE_EVENT      = isStage ? 'Global\\PiFocusPauseEventStage'  : 'Global\\PiFocusPauseEvent';
const HKLM_ROOT        = isStage ? 'SOFTWARE\\PiFocusStage'          : 'SOFTWARE\\PiFocus';
const HKLM_ROOT_FULL   = `HKLM\\${HKLM_ROOT}`;
// TrackingManager falls back to HKCU under the SAME subkey path when it cannot
// write HKLM (non-admin / console mode). Production runs as LocalSystem and
// always uses HKLM.
const HKCU_ROOT_FULL   = `HKCU\\${HKLM_ROOT}`;
const SERVICE_NAME     = isStage ? 'PiFocusWindowServiceStage'       : 'PiFocusWindowService';
const PROGRAMDATA_DIR  = isStage ? 'C:\\ProgramData\\PiFocusStage'   : 'C:\\ProgramData\\PiFocus';
const DEBUGLOG_DIR     = isStage
  ? 'C:\\ProgramData\\ProgramMonitorStage\\debugLogs'
  : 'C:\\ProgramData\\ProgramMonitor\\debugLogs';
const DAILY_REPORTS_DIR = isStage
  ? 'C:\\ProgramData\\ProgramMonitorStage\\daily_reports'
  : 'C:\\ProgramData\\ProgramMonitor\\daily_reports';

module.exports = {
  ENV,
  isStage,
  PIPE_NAME,
  PAUSE_EVENT,
  HKLM_ROOT,
  HKLM_ROOT_FULL,
  HKCU_ROOT_FULL,
  SERVICE_NAME,
  PROGRAMDATA_DIR,
  DEBUGLOG_DIR,
  DAILY_REPORTS_DIR,
};
