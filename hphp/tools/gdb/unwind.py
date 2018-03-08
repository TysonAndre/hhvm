"""
GDB commands related to the HHVM stack.
"""

from compatibility import *

import gdb
from gdb.unwinder import Unwinder, register_unwinder
from gdbutils import *
import frame


#------------------------------------------------------------------------------
# HHVM unwinder.

class FrameId(object):
    def __init__(self, sp, ip):
        self.sp = sp
        self.pc = ip

class HHVMUnwinder(Unwinder):
    """Custom unwinder for jitted frames.

Chases the frame pointer chain in frames which appear to be in the TC, and
falls back to the default GDB unwinder(s) otherwise.
"""

    def __init__(self):
        try:
            self.arch = gdb.newest_frame().architecture().name()
        except:
            self.arch = 'i386:x86-64'

        self.frame_reg = 'x29' if self.arch == 'aarch64' else 'rbp'
        self.stack_reg = 'sp' if self.arch == 'aarch64' else 'rsp'
        self.pc_reg = 'pc' if self.arch == 'aarch64' else 'rip'
        super(HHVMUnwinder, self).__init__('hhvm_unwinder')

    def __call__(self, pending_frame):
        fp = pending_frame.read_register(self.frame_reg)
        sp = pending_frame.read_register(self.stack_reg)
        ip = pending_frame.read_register(self.pc_reg)

        if not frame.is_jitted(fp, ip):
            return None

        # GDB wants a FrameId to be a pair of (stack pointer, starting PC) for
        # a given function frame.  Unfortunately, we can't restore the stack
        # pointer correctly in the TC, and we don't know our starting IP.
        #
        # Instead, we just use the stack pointer value for our most recent call
        # into native code, along with the current PC.  It turns out that this
        # is good enough.
        #
        # GDB expects stack pointers to be monotonically nondecreasing as we
        # unwind, so we can't use, e.g., the frame pointer as part of the ID.
        unwind_info = pending_frame.create_unwind_info(FrameId(sp, ip))

        # Restore the saved frame pointer and instruction pointer.
        fp = fp.cast(T('uintptr_t').pointer())
        unwind_info.add_saved_register(self.frame_reg, fp[0])
        unwind_info.add_saved_register(self.pc_reg, fp[1])

        if frame.is_jitted(fp[0], fp[1]):
            # Our parent frame is jitted.  Again, we are unable to track %rsp
            # properly in the TC, so just preserve its value (just as we do in
            # the TC's custom .eh_frame section).
            unwind_info.add_saved_register(self.stack_reg, sp)
        else:
            # Our parent frame is not jitted, so we're in enterTCHelper, and we
            # can restore our parent's %rsp as usual.
            unwind_info.add_saved_register(self.stack_reg, fp + 16)

        return unwind_info


#------------------------------------------------------------------------------
# Unwinder initialization.

_did_init = False

def try_unwinder_init():
    """Try to register the custom unwinder if it hasn't been already, and
    return whether the unwinder has been successfully registered."""
    global _did_init

    if _did_init:
        return True

    # If we can't successfully call is_jitted(), then gdb startup hasn't
    # proceeded to a point where it's safe to set up our unwinder yet, so just
    # bail out.
    try:
        frame.is_jitted(0, 0)
    except:
        return False

    register_unwinder(None, HHVMUnwinder())
    _did_init = True

    return True


class UnwinderCommand(gdb.Command):
    """Manage the custom unwinder."""

    def __init__(self):
        super(UnwinderCommand, self).__init__('unwinder', gdb.COMMAND_STACK,
                                              gdb.COMPLETE_NONE, True)

UnwinderCommand()

class UnwinderInitCommand(gdb.Command):
    """Initialize the custom unwinder."""

    def __init__(self):
        super(UnwinderInitCommand, self).__init__('unwinder init',
                                                  gdb.COMMAND_STACK)

    @errorwrap
    def invoke(self, args, from_tty):
        if try_unwinder_init():
            print('HHVM unwinder has been initialized.')
        else:
            print('HHVM unwinder could not be initialized.')
            print('Has gdb startup run to completion?')

UnwinderInitCommand()
