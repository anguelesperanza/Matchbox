package sce

// Hand-written ports of the SDK's `static inline` functions and function-like
// macros. They exist only in the headers, so there is nothing to link against.
// Each one follows the C source in the header named above it.

// ---------------------------------------------------------------
// psp2common/kernel/iofilemgr.h
// ---------------------------------------------------------------
S_ISLNK  :: #force_inline proc "contextless" (m: Mode) -> bool { return (u32(m) & S_IFMT) == S_IFLNK }
S_ISREG  :: #force_inline proc "contextless" (m: Mode) -> bool { return (u32(m) & S_IFMT) == S_IFREG }
S_ISDIR  :: #force_inline proc "contextless" (m: Mode) -> bool { return (u32(m) & S_IFMT) == S_IFDIR }
SO_ISLNK :: #force_inline proc "contextless" (m: u32) -> bool { return (m & SO_IFMT) == SO_IFLNK }
SO_ISREG :: #force_inline proc "contextless" (m: u32) -> bool { return (m & SO_IFMT) == SO_IFREG }
SO_ISDIR :: #force_inline proc "contextless" (m: u32) -> bool { return (m & SO_IFMT) == SO_IFDIR }

// ---------------------------------------------------------------
// psp2/audiodec.h, psp2/atrac.h
// ---------------------------------------------------------------
AUDIODEC_ROUND_UP :: #force_inline proc "contextless" (size: u32) -> u32 {
    return (size + AUDIODEC_ALIGNMENT_SIZE - 1) &~ (AUDIODEC_ALIGNMENT_SIZE - 1)
}
ATRAC_ROUND_UP :: #force_inline proc "contextless" (size: u32) -> u32 {
    return (size + ATRAC_ALIGNMENT_SIZE - 1) &~ (ATRAC_ALIGNMENT_SIZE - 1)
}

// ---------------------------------------------------------------
// psp2/rtc.h
// ---------------------------------------------------------------
sceRtcGetYear        :: #force_inline proc "contextless" (time: ^DateTime) -> i32 { return i32(time.year) }
sceRtcGetMonth       :: #force_inline proc "contextless" (time: ^DateTime) -> i32 { return i32(time.month) }
sceRtcGetDay         :: #force_inline proc "contextless" (time: ^DateTime) -> i32 { return i32(time.day) }
sceRtcGetHour        :: #force_inline proc "contextless" (time: ^DateTime) -> i32 { return i32(time.hour) }
sceRtcGetMinute      :: #force_inline proc "contextless" (time: ^DateTime) -> i32 { return i32(time.minute) }
sceRtcGetSecond      :: #force_inline proc "contextless" (time: ^DateTime) -> i32 { return i32(time.second) }
sceRtcGetMicrosecond :: #force_inline proc "contextless" (time: ^DateTime) -> i32 { return i32(time.microsecond) }

sceRtcSetYear :: proc "contextless" (time: ^DateTime, year: i32) -> i32 {
    if year < 1 || year > 9999 { return RTC_ERROR_INVALID_YEAR }
    time.year = u16(year)
    return 0
}
sceRtcSetMonth :: proc "contextless" (time: ^DateTime, month: i32) -> i32 {
    if month < 1 || month > 12 { return RTC_ERROR_INVALID_MONTH }
    time.month = u16(month)
    return 0
}
sceRtcSetDay :: proc "contextless" (time: ^DateTime, day: i32) -> i32 {
    if day < 1 || day > 31 { return RTC_ERROR_INVALID_DAY }
    time.day = u16(day)
    return 0
}
sceRtcSetHour :: proc "contextless" (time: ^DateTime, hour: i32) -> i32 {
    if hour < 0 || hour > 23 { return RTC_ERROR_INVALID_HOUR }
    time.hour = u16(hour)
    return 0
}
sceRtcSetMinute :: proc "contextless" (time: ^DateTime, minute: i32) -> i32 {
    if minute < 0 || minute > 59 { return RTC_ERROR_INVALID_MINUTE }
    time.minute = u16(minute)
    return 0
}
sceRtcSetSecond :: proc "contextless" (time: ^DateTime, second: i32) -> i32 {
    if second < 0 || second > 59 { return RTC_ERROR_INVALID_SECOND }
    time.second = u16(second)
    return 0
}
sceRtcSetMicrosecond :: proc "contextless" (time: ^DateTime, microsecond: i32) -> i32 {
    if microsecond < 0 || microsecond > 999999 { return RTC_ERROR_INVALID_MICROSECOND }
    time.microsecond = u32(microsecond)
    return 0
}

// The header's compatibility macros. Note the swapped argument order of the
// Convert* names compared with the functions they call.
sceRtcGetCurrentTickUtc         :: sceRtcGetCurrentTick
sceRtcGetCurrentNetworkTickUtc  :: sceRtcGetCurrentNetworkTick
sceRtcGetCurrentClockUtc        :: #force_inline proc "c" (time: ^DateTime) -> i32 { return sceRtcGetCurrentClock(time, 0) }
sceRtcConvertTime_tToDateTime   :: #force_inline proc "c" (t: i32, time: ^DateTime) -> i32 { return sceRtcSetTime_t(time, t) }
sceRtcConvertTime64_tToDateTime :: #force_inline proc "c" (t: u64, time: ^DateTime) -> i32 { return sceRtcSetTime64_t(time, t) }
sceRtcConvertDateTimeToTime_t   :: sceRtcGetTime_t
sceRtcConvertDateTimeToTime64_t :: sceRtcGetTime64_t
sceRtcConvertDosTimeToDateTime  :: #force_inline proc "c" (dos_time: u32, time: ^DateTime) -> i32 { return sceRtcSetDosTime(time, dos_time) }
sceRtcConvertDateTimeToDosTime  :: sceRtcGetDosTime
sceRtcConvertWin32TimeToDateTime :: #force_inline proc "c" (win32_time: ^u64, time: ^DateTime) -> i32 { return sceRtcSetWin32FileTime(time, win32_time^) }
sceRtcConvertDateTimeToWin32Time :: sceRtcGetWin32FileTime
sceRtcConvertTickToDateTime     :: #force_inline proc "c" (tick: ^RtcTick, time: ^DateTime) -> i32 { return sceRtcSetTick(time, tick) }
sceRtcConvertDateTimeToTick     :: sceRtcGetTick

// ---------------------------------------------------------------
// psp2/libssl.h
// ---------------------------------------------------------------
sceSslEnd :: sceSslTerm

// ---------------------------------------------------------------
// psp2/sharedfb.h
// ---------------------------------------------------------------
sceSharedFbOpen :: #force_inline proc "c" (index: i32) -> UID {
    return _sceSharedFbOpen(index, PSP2_SDK_VERSION)
}

// ---------------------------------------------------------------
// psp2/gxt.h
// ---------------------------------------------------------------
// Start address of the texture data inside a GXT file image.
sceGxtGetDataAddress :: #force_inline proc "contextless" (gxt: rawptr) -> rawptr {
    header := (^GxtHeader)(gxt)
    return rawptr(uintptr(gxt) + uintptr(header.dataOffset))
}

// ---------------------------------------------------------------
// psp2/common_dialog.h and the dialogs built on it
// ---------------------------------------------------------------
// The magic number is the constant plus the address of the parameter block.
_sceCommonDialogSetMagicNumber :: #force_inline proc "contextless" (param: ^CommonDialogParam) {
    param.magic = u32(COMMON_DIALOG_MAGIC_NUMBER) + u32(uintptr(param))
}

sceCommonDialogConfigParamInit :: proc "contextless" (param: ^CommonDialogConfigParam) {
    param^ = {}
    param.language          = .MAX_VALUE
    param.enterButtonAssign = .MAX_VALUE
    param.sdkVersion        = PSP2_SDK_VERSION
}

sceMsgDialogParamInit :: proc "contextless" (param: ^MsgDialogParam) {
    param^ = {}
    _sceCommonDialogSetMagicNumber(&param.commonParam)
    param.sdkVersion = PSP2_SDK_VERSION
}

sceImeDialogParamInit :: proc "contextless" (param: ^ImeDialogParam) {
    param^ = {}
    _sceCommonDialogSetMagicNumber(&param.commonParam)
    param.sdkVersion = PSP2_SDK_VERSION
}

sceImeParamInit :: proc "contextless" (param: ^ImeParam) {
    param^ = {}
    param.sdkVersion = PSP2_SDK_VERSION
}

sceIncomingDialogParamInit :: proc "contextless" (param: ^IncomingDialogParam) {
    param^ = {}
    param.sdkVersion = PSP2_SDK_VERSION
}

sceNetCheckDialogParamInit :: proc "contextless" (param: ^NetCheckDialogParam) {
    param^ = {}
    _sceCommonDialogSetMagicNumber(&param.commonParam)
    param.sdkVersion            = PSP2_SDK_VERSION
    param.defaultAgeRestriction = NETCHECK_DIALOG_INITIAL_AGE_RESTRICTION
}

scePhotoImportDialogParamInit :: proc "contextless" (param: ^PhotoImportDialogParam) {
    param^ = {}
    _sceCommonDialogSetMagicNumber(&param.commonParam)
    param.sdkVersion = PSP2_SDK_VERSION
}

scePhotoReviewDialogParamInit :: proc "contextless" (param: ^PhotoReviewDialogParam) {
    param^ = {}
    _sceCommonDialogSetMagicNumber(&param.commonParam)
    param.sdkVersion = PSP2_SDK_VERSION
}

// ---------------------------------------------------------------
// psp2/dmac5.h
// ---------------------------------------------------------------
@(private = "file")
dmac5_aes :: #force_inline proc "c" (src, dst: rawptr, length: Size, key: rawptr, keysize: Size, iv: rawptr, mode: u32) -> i32 {
    param := SblDmac5EncDecParam{src = src, dst = dst, length = length, key = key, keysize = keysize, iv = iv}
    return sceSblDmac5EncDec(&param, mode | (((u32(keysize) << 2) - 0x100) & 0x300))
}

// keysize is in bits (128, 192 or 256).
sceSblDmac5AesCbcEnc :: proc "c" (src, dst: rawptr, length: Size, key: rawptr, keysize: Size, iv: rawptr) -> i32 {
    return dmac5_aes(src, dst, length, key, keysize, iv, 1 | 8)
}
sceSblDmac5AesCbcDec :: proc "c" (src, dst: rawptr, length: Size, key: rawptr, keysize: Size, iv: rawptr) -> i32 {
    return dmac5_aes(src, dst, length, key, keysize, iv, 2 | 8)
}
sceSblDmac5AesCtrEnc :: proc "c" (src, dst: rawptr, length: Size, key: rawptr, keysize: Size, iv: rawptr) -> i32 {
    return dmac5_aes(src, dst, length, key, keysize, iv, 1 | 0x20)
}
sceSblDmac5AesCtrDec :: proc "c" (src, dst: rawptr, length: Size, key: rawptr, keysize: Size, iv: rawptr) -> i32 {
    return dmac5_aes(src, dst, length, key, keysize, iv, 2 | 0x20)
}

sceSblDmac5Sha256Digest :: proc "c" (src, dst: rawptr, length: Size) -> i32 {
    ctx: SblDmac5HashTransformContext
    param := SblDmac5HashTransformParam{src = src, dst = dst, length = length, key = nil, keysize = 0, ctx = &ctx}
    // SHA-256 initial state, stored big-endian.
    init := [8]u32be{0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19}
    ctx.state = transmute([8]u32)init
    ctx.length = 0
    return sceSblDmac5HashTransform(&param, 3 | 0x10, 0x800)
}
