package dev.pylon.pylon

import java.io.File

/**
 * The local shell's sandbox on Android (SPEC 13, G8): an isolatedProcess
 * service, so it runs under a UID of its own that Android allocates for
 * this process alone, with no permissions (no INTERNET: no network), no
 * storage (it cannot open Pylon's files directory, where PYLON_HOME, the
 * host list and the pins live), and no binder to anything but Pylon's
 * activity, which binds it (Symbolon's agent service needs a signature
 * permission an isolated UID never holds).
 *
 * For each local shell the activity hands it one end of a socket pair;
 * the service runs `libpylon_local.so --android ROWS COLS` (the Resid
 * launcher: it starts /system/bin/sh with an empty environment on a
 * pseudo-terminal of its own and confines itself) and relays the pair
 * to the launcher's standard input and output unchanged: the frames of
 * pylon-local (cli/pylon_local.resid). The launcher's error output goes
 * back as frames of type 7, text for the principal. Nothing else crosses.
 */
class LocalShellService : IsolatedRelayService() {
    companion object {
        const val DESCRIPTOR = "dev.pylon.pylon.LocalShell"
    }
    override val descriptor = DESCRIPTOR
    override fun command(exeDir: String, rows: Int, cols: Int) = listOf(File(exeDir, "libpylon_local.so").path, "--android", "$rows", "$cols")
    override fun cannotStart(why: String?) = "This device does not let Pylon's sandbox start a shell ($why). The local shell does not start."
}
