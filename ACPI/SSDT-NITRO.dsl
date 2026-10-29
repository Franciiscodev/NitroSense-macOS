/*
 * SSDT-NITRO — EC access for NitroEC.kext on Acer Nitro 5 AN515-52 (macOS only).
 *
 * The firmware maps EC RAM 1:1 at SystemMemory 0xFC7E0800 (DSDT region ECMM
 * under \_SB.PCI0.LPCB.EC0) and accesses every EC field through it. We use the
 * same window, with the same Lock semantics, so no raw 0x62/0x66 port I/O happens.
 *
 * v1: read-only. v2: WE1B byte write. v3: WMBX -> firmware WMBH (gaming WMI).
 * v4: WMEX -> firmware WMBE (battery health WMI). Which offsets/values may be written is
 * decided by NitroEC.kext (whitelist), so new features need no SSDT change.
 *
 * Also gives VoodooPS2Keyboard an RMCF that maps the NitroSense key (PS/2 scancode e0 75,
 * "KEYBOARD_KEY_f5" in Linux hwdb) to F20 so NitroSense.app can catch it as a hotkey.
 */
DefinitionBlock ("", "SSDT", 2, "NITRO", "NITROEC", 0x00001000)
{
    External (_SB_.PCI0.WMID.WMBE, MethodObj)    // 3 Arguments
    External (_SB_.PCI0.WMID.WMBH, MethodObj)    // 3 Arguments
    External (_SB_.PCI0.LPCB.PS2K, DeviceObj)

    Scope (\_SB.PCI0.LPCB.PS2K)
    {
        Name (RMCF, Package ()
        {
            "Keyboard", Package ()
            {
                "Custom ADB Map", Package ()
                {
                    Package () {},
                    "e075=5a",  // NitroSense key -> F20
                },
            },
        })
    }

    Scope (\_SB)
    {
        Device (NTRO)
        {
            Name (_HID, "NTRO0001")  // _HID: Hardware ID
            Name (_UID, Zero)  // _UID: Unique ID

            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                If (_OSI ("Darwin"))
                {
                    Return (0x0F)
                }

                Return (Zero)
            }

            // Interface version, checked by the kext
            Method (VERS, 0, NotSerialized)
            {
                Return (0x04)
            }

            // EC RAM window 0x00..0xFF, same mapping as the firmware's ECMM (0xFC7E0800)
            OperationRegion (ERDM, SystemMemory, 0xFC7E0800, 0x0100)
            Field (ERDM, ByteAcc, Lock, Preserve)
            {
                BUF0,   2048
            }

            // Read one EC byte: RE1B (offset) -> 0x00..0xFF, Ones on bad offset
            Method (RE1B, 1, Serialized)
            {
                If ((Arg0 > 0xFF))
                {
                    Return (Ones)
                }

                Local0 = BUF0 /* \_SB_.NTRO.BUF0 */
                Return (DerefOf (Local0 [Arg0]))
            }

            // Write one EC byte: WE1B (offset, value) -> Zero, Ones on bad args
            Method (WE1B, 2, Serialized)
            {
                If (((Arg0 > 0xFF) || (Arg1 > 0xFF)))
                {
                    Return (Ones)
                }

                OperationRegion (EWB1, SystemMemory, (0xFC7E0800 + Arg0), One)
                Field (EWB1, ByteAcc, Lock, Preserve)
                {
                    BYT0,   8
                }

                BYT0 = Arg1
                Return (Zero)
            }

            // Call the firmware gaming WMI method the way NitroSense does:
            // WMBX (opcode, Buffer) -> WMBH (0, opcode, Buffer). Opcodes are
            // whitelisted by NitroEC.kext.
            Method (WMBX, 2, Serialized)
            {
                If (CondRefOf (\_SB.PCI0.WMID.WMBH))
                {
                    Return (\_SB.PCI0.WMID.WMBH (Zero, Arg0, Arg1))
                }

                Return (Buffer (0x04)
                {
                     0xFF, 0xFF, 0xFF, 0xFF
                })
            }

            // Battery health WMI the way NitroSense does it:
            // WMEX (method, Buffer) -> WMBE (0, method, Buffer). Whitelisted by the kext.
            Method (WMEX, 2, Serialized)
            {
                If (CondRefOf (\_SB.PCI0.WMID.WMBE))
                {
                    Return (\_SB.PCI0.WMID.WMBE (Zero, Arg0, Arg1))
                }

                Return (Buffer (0x04)
                {
                     0xFF, 0xFF, 0xFF, 0xFF
                })
            }

            // Read EC bytes 0x00..0xFF -> Buffer (0x100)
            Method (RDMP, 0, Serialized)
            {
                Return (BUF0) /* \_SB_.NTRO.BUF0 */
            }
        }
    }
}
