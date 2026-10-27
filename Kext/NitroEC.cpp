#include "NitroEC.hpp"
#include "NitroECShared.h"

#include <IOKit/IOLib.h>
#include <libkern/c++/OSData.h>
#include <libkern/c++/OSNumber.h>

#define LOG(fmt, ...) IOLog("NitroEC: " fmt "\n", ##__VA_ARGS__)

OSDefineMetaClassAndStructors(NitroEC, IOService)
OSDefineMetaClassAndStructors(NitroECUserClient, IOUserClient)

// MARK: - Write whitelist (AN515-57, verified against DSDT + OpeNitro/Packss)

enum : uint32_t {
    kRegPowerFlags  = 0x03,  // LMEN bit0, PSEE bit4 (set by firmware WMBH 0x05), BTHE bit6
    kPSEEBit        = 0x10,
    kRegKBTimeout   = 0x06,  // 0x1E = backlight off after 30 s idle, 0x00 = always on
    kRegUSBCharge   = 0x08,  // 0x0F = USB power-off charging on, 0x1F = off
    kRegGPUFanMode  = 0x21,
    kRegCPUFanMode  = 0x22,
    kRegCPUFanSpeed = 0x37,
    kRegGPUFanSpeed = 0x3A,

    kCPUFanAuto = 0x04, kCPUFanMax = 0x08, kCPUFanManual = 0x0C,
    kGPUFanAuto = 0x10, kGPUFanMax = 0x20, kGPUFanManual = 0x30,

    // Manual duty is a percentage: firmware WMBH 0x10 rejects > 100. Below 20 %
    // is refused so a typo can never park a fan.
    kFanSpeedMin = 20, kFanSpeedMax = 100,

    // Firmware gaming WMI (\_SB.PC00.WMID.WMBH) opcodes. 0x01-0x04, 0x08-0x0F,
    // 0x18, 0x19 are forwarded to BIOS SMM (WSMI); the rest touch EC fields.
    kWMBHSetGamingLED = 0x02, // SMM. AN515-57 needs [08 .. byte5 = zone mask] to light the 4-zone keyboard
    kWMBHGetGamingLED = 0x04, // SMM
    kWMBHGetSensor   = 0x05,  // also sets PSEE
    kWMBHSetZoneRGB  = 0x06,
    kWMBHGetZoneRGB  = 0x07,
    kWMBHSetFanSpeed = 0x10,
    kWMBHGetFanSpeed = 0x11,
    kWMBHGetFanTable = 0x13,
    kWMBHSetLEDMode  = 0x14,
    kWMBHGetLEDMode  = 0x15,
    kWMBHSetMisc     = 0x16,  // only sub-function 0x0B (OPMS / nitro mode)
};

static bool isZoneMask(uint8_t v) { return v == 1 || v == 2 || v == 4 || v == 8; }
static bool isFanGroup(uint8_t v) { return v == 1 || v == 4; }

bool NitroEC::isWriteAllowed(uint32_t offset, uint32_t value) {
    switch (offset) {
    case kRegCPUFanMode:
        return value == kCPUFanAuto || value == kCPUFanMax || value == kCPUFanManual;
    case kRegGPUFanMode:
        return value == kGPUFanAuto || value == kGPUFanMax || value == kGPUFanManual;
    case kRegCPUFanSpeed:
    case kRegGPUFanSpeed:
        return value >= kFanSpeedMin && value <= kFanSpeedMax;
    case kRegKBTimeout:
        return value == 0x00 || value == 0x1E;
    case kRegUSBCharge:
        return value == 0x0F || value == 0x1F;
    case kRegPowerFlags:
        return true;  // writeByte() only lets the PSEE bit change
    default:
        return false;
    }
}

// Battery-health WMI (\_SB.PC00.WMID.WMBE), all forwarded to BIOS SMM.
// Layout from Linuwu-Sense: get [battery 1, query 1], set [battery 1, mask, status].
enum : uint32_t {
    kWMBEGetHealth = 0x14,
    kWMBESetHealth = 0x15,
    kHealthMaskLimit = 0x01,  // 80 % charge limit. Calibration (0x02) is deliberately not allowed.
};

static bool isZeroFrom(const uint8_t *in, uint32_t start) {
    for (uint32_t i = start; i < kNitroECWMBHInSize; i++)
        if (in[i])
            return false;
    return true;
}

bool NitroEC::isWMBHAllowed(uint32_t opcode, const uint8_t *in) {
    switch (opcode) {
    case kWMBHSetGamingLED:
        // Only the keyboard zone-enable form used by the Linux driver for AN515-57.
        return in[0] == 0x08 && !in[1] && !in[2] && !in[3] && !in[4] && in[5] <= 0x0F && isZeroFrom(in, 6);
    case kWMBHGetGamingLED:
        return in[0] == 0x08 && isZeroFrom(in, 1);
    case kWMBHGetSensor:
        return in[0] <= 2;
    case kWMBHSetZoneRGB:
    case kWMBHGetZoneRGB:
        return isZoneMask(in[0]);
    case kWMBHSetFanSpeed:
        return isFanGroup(in[0]) && in[1] >= kFanSpeedMin && in[1] <= kFanSpeedMax;
    case kWMBHGetFanSpeed:
        return isFanGroup(in[0]);
    case kWMBHGetFanTable:
    case kWMBHSetLEDMode:
    case kWMBHGetLEDMode:
        return true;
    case kWMBHSetMisc:
        return in[0] == 0x0B && (in[1] == 0x00 || in[1] == 0x01 || in[1] == 0x04);
    default:
        return false;
    }
}

bool NitroEC::isWMBEAllowed(uint32_t method, const uint8_t *in) {
    switch (method) {
    case kWMBEGetHealth:
        return in[0] == 1 && in[1] == kHealthMaskLimit && isZeroFrom(in, 2);
    case kWMBESetHealth:
        return in[0] == 1 && in[1] == kHealthMaskLimit && in[2] <= 1 && isZeroFrom(in, 3);
    default:
        return false;
    }
}

// MARK: - NitroEC

bool NitroEC::start(IOService *provider) {
    if (!IOService::start(provider))
        return false;

    acpi = OSDynamicCast(IOACPIPlatformDevice, provider);
    if (!acpi) {
        LOG("provider is not an ACPI device");
        return false;
    }

    UInt32 version = 0;
    if (acpi->evaluateInteger("VERS", &version) != kIOReturnSuccess || version != kNitroECACPIVersion) {
        LOG("SSDT-NITRO missing or wrong version (got %u, want %u)", version, kNitroECACPIVersion);
        return false;
    }

    lock = IOLockAlloc();
    if (!lock)
        return false;

    acpi->retain();

    uint8_t cpuTemp = 0;
    if (readByte(0xB0, &cpuTemp) == kIOReturnSuccess)
        LOG("started, SSDT v%u, CPU temp %u C", version, cpuTemp);

    setProperty("NitroEC SSDT Version", version, 32);
    registerService();
    return true;
}

void NitroEC::stop(IOService *provider) {
    // Never leave the fans in manual mode without a driver behind them.
    writeByte(kRegCPUFanMode, kCPUFanAuto);
    writeByte(kRegGPUFanMode, kGPUFanAuto);
    OSSafeReleaseNULL(acpi);
    IOService::stop(provider);
}

void NitroEC::free() {
    if (lock) {
        IOLockFree(lock);
        lock = nullptr;
    }
    IOService::free();
}

IOReturn NitroEC::readByte(uint32_t offset, uint8_t *value) {
    if (offset >= kNitroECDumpSize || !value)
        return kIOReturnBadArgument;

    OSNumber *arg = OSNumber::withNumber(offset, 32);
    if (!arg)
        return kIOReturnNoMemory;

    OSObject *params[] = {arg};
    UInt32 result = 0;
    IOLockLock(lock);
    IOReturn ret = acpi->evaluateInteger("RE1B", &result, params, 1);
    IOLockUnlock(lock);
    arg->release();

    if (ret != kIOReturnSuccess)
        return ret;
    if (result > 0xFF)
        return kIOReturnError;

    *value = static_cast<uint8_t>(result);
    return kIOReturnSuccess;
}

IOReturn NitroEC::dump(uint8_t *buffer, uint32_t length) {
    if (!buffer || length < kNitroECDumpSize)
        return kIOReturnBadArgument;

    OSObject *result = nullptr;
    IOLockLock(lock);
    IOReturn ret = acpi->evaluateObject("RDMP", &result);
    IOLockUnlock(lock);
    if (ret != kIOReturnSuccess)
        return ret;

    OSData *data = OSDynamicCast(OSData, result);
    if (!data || data->getLength() < kNitroECDumpSize) {
        OSSafeReleaseNULL(result);
        return kIOReturnUnderrun;
    }

    memcpy(buffer, data->getBytesNoCopy(), kNitroECDumpSize);
    result->release();
    return kIOReturnSuccess;
}

IOReturn NitroEC::writeByte(uint32_t offset, uint32_t value) {
    if (!isWriteAllowed(offset, value)) {
        LOG("refused write 0x%02X = 0x%02X (not whitelisted)", offset, value);
        return kIOReturnNotPermitted;
    }
    if (!acpi)
        return kIOReturnNotReady;

    if (offset == kRegPowerFlags) {
        uint8_t current = 0;
        IOReturn ret = readByte(offset, &current);
        if (ret != kIOReturnSuccess)
            return ret;
        if ((current ^ value) & ~kPSEEBit) {
            LOG("refused write 0x03 = 0x%02X (only PSEE may change, current 0x%02X)", value, current);
            return kIOReturnNotPermitted;
        }
    }

    OSNumber *argOffset = OSNumber::withNumber(offset, 32);
    OSNumber *argValue = OSNumber::withNumber(value, 32);
    if (!argOffset || !argValue) {
        OSSafeReleaseNULL(argOffset);
        OSSafeReleaseNULL(argValue);
        return kIOReturnNoMemory;
    }

    OSObject *params[] = {argOffset, argValue};
    UInt32 result = 0;
    IOLockLock(lock);
    IOReturn ret = acpi->evaluateInteger("WE1B", &result, params, 2);
    IOLockUnlock(lock);
    argOffset->release();
    argValue->release();

    if (ret != kIOReturnSuccess)
        return ret;
    if (result != 0)
        return kIOReturnError;

    LOG("wrote 0x%02X = 0x%02X", offset, value);
    return kIOReturnSuccess;
}

IOReturn NitroEC::callWMBH(uint32_t opcode, const uint8_t *in, uint8_t *out, uint32_t *outLength) {
    if (!isWMBHAllowed(opcode, in)) {
        LOG("refused WMBH 0x%02X [%02X %02X] (not whitelisted)", opcode, in[0], in[1]);
        return kIOReturnNotPermitted;
    }
    return callWMI("WMBX", opcode, in, out, outLength);
}

IOReturn NitroEC::callWMBE(uint32_t method, const uint8_t *in, uint8_t *out, uint32_t *outLength) {
    if (!isWMBEAllowed(method, in)) {
        LOG("refused WMBE 0x%02X [%02X %02X %02X] (not whitelisted)", method, in[0], in[1], in[2]);
        return kIOReturnNotPermitted;
    }
    return callWMI("WMEX", method, in, out, outLength);
}

IOReturn NitroEC::callWMI(const char *wrapper, uint32_t opcode, const uint8_t *in, uint8_t *out, uint32_t *outLength) {
    if (!acpi)
        return kIOReturnNotReady;

    OSNumber *argOpcode = OSNumber::withNumber(opcode, 32);
    OSData *argBuffer = OSData::withBytes(in, kNitroECWMBHInSize);
    if (!argOpcode || !argBuffer) {
        OSSafeReleaseNULL(argOpcode);
        OSSafeReleaseNULL(argBuffer);
        return kIOReturnNoMemory;
    }

    OSObject *params[] = {argOpcode, argBuffer};
    OSObject *result = nullptr;
    IOLockLock(lock);
    IOReturn ret = acpi->evaluateObject(wrapper, &result, params, 2);
    IOLockUnlock(lock);
    argOpcode->release();
    argBuffer->release();
    if (ret != kIOReturnSuccess)
        return ret;

    OSData *data = OSDynamicCast(OSData, result);
    if (!data) {
        OSSafeReleaseNULL(result);
        return kIOReturnError;
    }
    uint32_t length = min(data->getLength(), *outLength);
    memcpy(out, data->getBytesNoCopy(), length);
    *outLength = length;
    result->release();

    LOG("%s 0x%02X [%02X %02X %02X %02X %02X %02X] -> %02X", wrapper, opcode, in[0], in[1], in[2], in[3], in[4], in[5],
        length ? out[0] : 0xFF);
    return kIOReturnSuccess;
}

// MARK: - NitroECUserClient

const IOExternalMethodDispatch NitroECUserClient::methods[kNitroECSelCount] = {
    // function, scalarIn, structIn, scalarOut, structOut
    [kNitroECSelReadByte]  = {&NitroECUserClient::sReadByte, 1, 0, 1, 0},
    [kNitroECSelDump]      = {&NitroECUserClient::sDump, 0, 0, 0, kNitroECDumpSize},
    [kNitroECSelWriteByte] = {&NitroECUserClient::sWriteByte, 2, 0, 1, 0},
    [kNitroECSelWMBH]      = {&NitroECUserClient::sWMBH, 1, kNitroECWMBHInSize, 0, kIOUCVariableStructureSize},
    [kNitroECSelWMBE]      = {&NitroECUserClient::sWMBE, 1, kNitroECWMBHInSize, 0, kIOUCVariableStructureSize},
};

bool NitroECUserClient::initWithTask(task_t owningTask, void *securityID, UInt32 type) {
    if (!IOUserClient::initWithTask(owningTask, securityID, type))
        return false;
    isAdmin = clientHasPrivilege(owningTask, kIOClientPrivilegeAdministrator) == kIOReturnSuccess;
    return true;
}

bool NitroECUserClient::start(IOService *provider) {
    owner = OSDynamicCast(NitroEC, provider);
    if (!owner)
        return false;
    return IOUserClient::start(provider);
}

IOReturn NitroECUserClient::clientClose() {
    terminate();
    return kIOReturnSuccess;
}

IOReturn NitroECUserClient::externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                                           IOExternalMethodDispatch *, OSObject *, void *) {
    if (selector >= kNitroECSelCount)
        return kIOReturnUnsupported;
    return IOUserClient::externalMethod(selector, args,
                                        const_cast<IOExternalMethodDispatch *>(&methods[selector]),
                                        this, nullptr);
}

IOReturn NitroECUserClient::sReadByte(OSObject *target, void *, IOExternalMethodArguments *args) {
    auto self = static_cast<NitroECUserClient *>(target);
    uint8_t value = 0;
    IOReturn ret = self->owner->readByte(static_cast<uint32_t>(args->scalarInput[0]), &value);
    if (ret == kIOReturnSuccess)
        args->scalarOutput[0] = value;
    return ret;
}

IOReturn NitroECUserClient::sDump(OSObject *target, void *, IOExternalMethodArguments *args) {
    auto self = static_cast<NitroECUserClient *>(target);
    if (args->structureOutputSize < kNitroECDumpSize)
        return kIOReturnBadArgument;
    return self->owner->dump(static_cast<uint8_t *>(args->structureOutput), kNitroECDumpSize);
}

IOReturn NitroECUserClient::sWriteByte(OSObject *target, void *, IOExternalMethodArguments *args) {
    auto self = static_cast<NitroECUserClient *>(target);
    if (!self->isAdmin)
        return kIOReturnNotPrivileged;

    uint32_t offset = static_cast<uint32_t>(args->scalarInput[0]);
    uint32_t value = static_cast<uint32_t>(args->scalarInput[1]);
    if (args->scalarInput[0] > 0xFF || args->scalarInput[1] > 0xFF)
        return kIOReturnBadArgument;

    IOReturn ret = self->owner->writeByte(offset, value);
    if (ret != kIOReturnSuccess)
        return ret;

    uint8_t readBack = 0;
    ret = self->owner->readByte(offset, &readBack);
    if (ret == kIOReturnSuccess)
        args->scalarOutput[0] = readBack;
    return ret;
}

IOReturn NitroECUserClient::sWMBH(OSObject *target, void *, IOExternalMethodArguments *args) {
    return sWMI(target, args, false);
}

IOReturn NitroECUserClient::sWMBE(OSObject *target, void *, IOExternalMethodArguments *args) {
    return sWMI(target, args, true);
}

IOReturn NitroECUserClient::sWMI(OSObject *target, IOExternalMethodArguments *args, bool battery) {
    auto self = static_cast<NitroECUserClient *>(target);
    if (!self->isAdmin)
        return kIOReturnNotPrivileged;
    if (args->scalarInput[0] > 0xFF || args->structureOutputSize == 0)
        return kIOReturnBadArgument;

    uint32_t opcode = static_cast<uint32_t>(args->scalarInput[0]);
    auto in = static_cast<const uint8_t *>(args->structureInput);
    auto out = static_cast<uint8_t *>(args->structureOutput);
    uint32_t outLength = min(args->structureOutputSize, (uint32_t)kNitroECWMBHOutSize);
    IOReturn ret = battery ? self->owner->callWMBE(opcode, in, out, &outLength)
                           : self->owner->callWMBH(opcode, in, out, &outLength);
    if (ret == kIOReturnSuccess)
        args->structureOutputSize = outLength;
    return ret;
}
