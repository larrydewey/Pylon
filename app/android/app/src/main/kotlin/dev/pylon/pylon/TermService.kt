package dev.pylon.pylon

import java.io.File

/**
 * The terminal emulator's sandbox on Android (SPEC 12): an isolatedProcess
 * service, bound once per terminal with its own instance name
 * (Context.bindIsolatedService), so each terminal's emulator and the relay
 * that carries its bytes run in a process of their own, apart from the
 * local shell's and from every other terminal's. The emulator, the largest parser of bytes a hostile host controls,
 * runs under a UID Android allocates for it alone, with no permissions (no
 * network), no storage, and no binder to Symbolon (whose agent needs a
 * signature permission an isolated UID never holds). Phones' kernels have
 * no Landlock, the confinement pylon-term applies itself on Linux; here
 * the platform confines it, and `--android` tells it so.
 *
 * One `libpylon_term.so ROWS COLS --android` per instance, so one per
 * terminal: an emulator a hostile host's output took over can reach that
 * terminal's socket and nothing else (no other host's bytes, no
 * connection, which `libpylon.so` holds in Pylon's own process). Unbinding
 * the instance, when its terminal ends, ends the process. Its frames
 * (cli/pylon_term.resid) cross unchanged.
 */
class TermService : IsolatedRelayService() {
    companion object {
        const val DESCRIPTOR = "dev.pylon.pylon.Term"
    }
    override val descriptor = DESCRIPTOR
    override fun command(exeDir: String, rows: Int, cols: Int) = listOf(File(exeDir, "libpylon_term.so").path, "$rows", "$cols", "--android")
    override fun cannotStart(why: String?) = "This device does not let Pylon's sandbox start the terminal emulator ($why)."
}
