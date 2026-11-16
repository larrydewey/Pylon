package dev.pylon.pylon

import java.io.File

/**
 * The terminal emulator's sandbox on Android (SPEC 12): an isolatedProcess
 * service in a process of its own (":term", apart from the local shell's),
 * so the emulator, the largest parser of bytes a hostile host controls,
 * runs under a UID Android allocates for it alone, with no permissions (no
 * network), no storage, and no binder to Symbolon (whose agent needs a
 * signature permission an isolated UID never holds). Phones' kernels have
 * no Landlock, the confinement pylon-term applies itself on Linux; here
 * the platform confines it, and `--android` tells it so.
 *
 * One `libpylon_term.so ROWS COLS --android` per terminal; its frames
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
