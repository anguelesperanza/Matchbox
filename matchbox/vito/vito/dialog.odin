package vito

// The system dialogs: message boxes, a progress bar, and the on-screen
// keyboard (the IME dialog).
//
// The system draws a dialog on top of the game's own frame, so the game keeps
// running its loop while one is open and has to do three things:
//
//   1. call dialog_init() once at start-up
//   2. every frame, after the scene is finished and before the buffers are
//      swapped, hand the frame to the dialog. With vita2d that is
//          v2d.EndDrawing()
//          v2d.CommonDialogUpdate()
//          v2d.SwapBuffers()
//   3. every frame, poll the dialog that is open (message_dialog_poll or
//      text_input_poll) until it reports done
//
// Only one dialog can be open at a time. The buttons still reach the game
// while a dialog is open, so skip the game's own input when dialog_active()
// is true.
//
// Link: -lSceCommonDialog_stub -lSceAppUtil_stub

import "core:unicode/utf16"
import sce "../sce"

Dialog_Kind :: enum {
    None,
    Message,
    Text_Input,
}

Message_Buttons :: enum {
    Ok,
    Yes_No,
    Ok_Cancel,
    Cancel,
    None,    // no buttons; close it with message_dialog_close
    Three,   // three buttons with the labels passed to message_dialog_open
}

Message_Result :: struct {
    // 1 is OK, Yes or the first button; 2 is No or the second; 3 the third.
    // 0 if no button was chosen.
    button:   int,
    // The dialog was cancelled by the user, or closed by the game.
    canceled: bool,
}

Text_Input_Type :: enum u32 {
    Default         = sce.IME_TYPE_DEFAULT,
    Basic_Latin     = sce.IME_TYPE_BASIC_LATIN,
    Number          = sce.IME_TYPE_NUMBER,
    Extended_Number = sce.IME_TYPE_EXTENDED_NUMBER,
    Url             = sce.IME_TYPE_URL,
    Mail            = sce.IME_TYPE_MAIL,
}

Text_Input_Option :: enum {
    Multiline,
    No_Auto_Capitalization,
    No_Assistance,
    Password,     // show dots instead of the text
}
Text_Input_Options :: bit_set[Text_Input_Option]

// The longest text the keyboard accepts, in UTF-16 units.
TEXT_INPUT_MAX_LENGTH :: sce.IME_DIALOG_MAX_TEXT_LENGTH

@(private = "file") dialog_kind: Dialog_Kind
// The last error an open call got from the system, 0 if it worked.
dialog_last_error: i32

// The dialogs keep pointers to their text, so it lives here, not on a stack.
@(private = "file") msg_text:    [sce.MSG_DIALOG_USER_MSG_SIZE]u8
@(private = "file") msg_labels:  [3][64]u8
@(private = "file") ime_title:   [sce.IME_DIALOG_MAX_TITLE_LENGTH + 1]u16
@(private = "file") ime_initial: [TEXT_INPUT_MAX_LENGTH + 1]u16
@(private = "file") ime_buffer:  [TEXT_INPUT_MAX_LENGTH + 1]u16

// Tells the dialog system which language and which confirm button (Cross or
// Circle) the console is set to. Call once, before opening any dialog.
// It needs SceAppUtil; pass init_app_util = false if the game has already
// called sceAppUtilInit itself.
dialog_init :: proc "contextless" (init_app_util := true) -> bool {
    if init_app_util {
        init_param: sce.AppUtilInitParam
        boot_param: sce.AppUtilBootParam
        sce.sceAppUtilInit(&init_param, &boot_param) // fails harmlessly if already done
    }
    config: sce.CommonDialogConfigParam
    sce.sceCommonDialogConfigParamInit(&config)
    sce.sceAppUtilSystemParamGetInt(sce.SYSTEM_PARAM_ID_LANG, (^i32)(&config.language))
    sce.sceAppUtilSystemParamGetInt(sce.SYSTEM_PARAM_ID_ENTER_BUTTON, (^i32)(&config.enterButtonAssign))
    dialog_last_error = sce.sceCommonDialogSetConfigParam(&config)
    return dialog_last_error >= 0
}

// Which dialog is open, .None if there is none.
dialog_open_kind :: proc "contextless" () -> Dialog_Kind {
    return dialog_kind
}

dialog_active :: proc "contextless" () -> bool {
    return dialog_kind != .None
}

// Asks the open dialog to go away without an answer. It still has to be
// polled until it reports done.
dialog_abort :: proc "contextless" () {
    switch dialog_kind {
    case .Message:    sce.sceMsgDialogAbort()
    case .Text_Input: sce.sceImeDialogAbort()
    case .None:
    }
}

// ---------------------------------------------------------------
// Message dialogs
// ---------------------------------------------------------------

// Opens a message box. The text can be up to 511 bytes of UTF-8 and may
// contain line breaks. labels are used only with Message_Buttons.Three.
message_dialog_open :: proc "contextless" (text: string, buttons := Message_Buttons.Ok, labels: [3]string = {}) -> bool {
    if dialog_kind != .None do return false

    copy_cstring(msg_text[:], text)
    user: sce.MsgDialogUserMessageParam
    user.msg = cstring(&msg_text[0])

    button_param: sce.MsgDialogButtonsParam
    switch buttons {
    case .Ok:        user.buttonType = sce.MSG_DIALOG_BUTTON_TYPE_OK
    case .Yes_No:    user.buttonType = sce.MSG_DIALOG_BUTTON_TYPE_YESNO
    case .Ok_Cancel: user.buttonType = sce.MSG_DIALOG_BUTTON_TYPE_OK_CANCEL
    case .Cancel:    user.buttonType = sce.MSG_DIALOG_BUTTON_TYPE_CANCEL
    case .None:      user.buttonType = sce.MSG_DIALOG_BUTTON_TYPE_NONE
    case .Three:
        user.buttonType = sce.MSG_DIALOG_BUTTON_TYPE_3BUTTONS
        for label, i in labels do copy_cstring(msg_labels[i][:], label)
        button_param.msg1 = cstring(&msg_labels[0][0])
        button_param.msg2 = cstring(&msg_labels[1][0])
        button_param.msg3 = cstring(&msg_labels[2][0])
        user.buttonParam = &button_param
    }

    param: sce.MsgDialogParam
    sce.sceMsgDialogParamInit(&param)
    param.mode         = sce.MSG_DIALOG_MODE_USER_MSG
    param.userMsgParam = &user
    return open_message(&param)
}

// Opens the system's own "an error occurred" box showing an SCE error code.
error_dialog_open :: proc "contextless" (code: i32) -> bool {
    if dialog_kind != .None do return false
    error_param: sce.MsgDialogErrorCodeParam
    error_param.errorCode = code

    param: sce.MsgDialogParam
    sce.sceMsgDialogParamInit(&param)
    param.mode           = sce.MSG_DIALOG_MODE_ERROR_CODE
    param.errorCodeParam = &error_param
    return open_message(&param)
}

// Opens one of the system's ready-made messages, in the console's language
// (sce.MSG_DIALOG_SYSMSG_TYPE_*; WAIT is "Please wait..." with a spinner).
// Those without a button stay until message_dialog_close is called.
system_message_dialog_open :: proc "contextless" (type: i32, value: i32 = 0) -> bool {
    if dialog_kind != .None do return false
    system: sce.MsgDialogSystemMessageParam
    system.sysMsgType = type
    system.value      = value

    param: sce.MsgDialogParam
    sce.sceMsgDialogParamInit(&param)
    param.mode        = sce.MSG_DIALOG_MODE_SYSTEM_MSG
    param.sysMsgParam = &system
    return open_message(&param)
}

// Opens a box with a progress bar at 0 %. Move it with progress_dialog_set
// and close it with message_dialog_close when the work is done.
progress_dialog_open :: proc "contextless" (text: string) -> bool {
    if dialog_kind != .None do return false
    copy_cstring(msg_text[:], text)
    progress: sce.MsgDialogProgressBarParam
    progress.barType = sce.MSG_DIALOG_PROGRESSBAR_TYPE_PERCENTAGE
    progress.msg     = cstring(&msg_text[0])

    param: sce.MsgDialogParam
    sce.sceMsgDialogParamInit(&param)
    param.mode         = sce.MSG_DIALOG_MODE_PROGRESS_BAR
    param.progBarParam = &progress
    return open_message(&param)
}

// percent is 0 to 100.
progress_dialog_set :: proc "contextless" (percent: int) -> i32 {
    return sce.sceMsgDialogProgressBarSetValue(sce.MSG_DIALOG_PROGRESSBAR_TARGET_BAR_DEFAULT, u32(clamp(percent, 0, 100)))
}

// Replaces the text of an open progress dialog.
progress_dialog_set_text :: proc "contextless" (text: string) -> i32 {
    copy_cstring(msg_text[:], text)
    return sce.sceMsgDialogProgressBarSetMsg(sce.MSG_DIALOG_PROGRESSBAR_TARGET_BAR_DEFAULT, cstring(&msg_text[0]))
}

// Closes the open message dialog from the game's side, with its closing
// animation. Poll it until done as usual.
message_dialog_close :: proc "contextless" () -> i32 {
    if dialog_kind != .Message do return 0
    return sce.sceMsgDialogClose()
}

// Call every frame while a message dialog is open. done is true on the one
// frame the dialog has finished; the result is valid then.
message_dialog_poll :: proc "contextless" () -> (result: Message_Result, done: bool) {
    if dialog_kind != .Message do return
    if sce.sceMsgDialogGetStatus() != .FINISHED do return

    raw: sce.MsgDialogResult
    sce.sceMsgDialogGetResult(&raw)
    sce.sceMsgDialogTerm()
    dialog_kind = .None

    result.button   = int(raw.buttonId)
    result.canceled = u32(raw.result) != sce.COMMON_DIALOG_RESULT_OK
    return result, true
}

// ---------------------------------------------------------------
// Text input (the on-screen keyboard)
// ---------------------------------------------------------------

// Opens the keyboard with a title line and the text to start from.
// max_length is in characters (UTF-16 units), at most TEXT_INPUT_MAX_LENGTH.
text_input_open :: proc(title: string, initial := "", max_length := 64,
                                       type := Text_Input_Type.Default, options: Text_Input_Options = {}) -> bool {
    if dialog_kind != .None do return false
    limit := clamp(max_length, 1, TEXT_INPUT_MAX_LENGTH)

    to_utf16(ime_title[:], title)
    to_utf16(ime_initial[:limit + 1], initial)
    ime_buffer = {}

    param: sce.ImeDialogParam
    sce.sceImeDialogParamInit(&param)
    param.supportedLanguages = 0 // the languages chosen in the console's settings
    param.type               = u32(type)
    if .Multiline              in options do param.option |= sce.IME_OPTION_MULTILINE
    if .No_Auto_Capitalization in options do param.option |= sce.IME_OPTION_NO_AUTO_CAPITALIZATION
    if .No_Assistance          in options do param.option |= sce.IME_OPTION_NO_ASSISTANCE
    param.dialogMode      = sce.IME_DIALOG_DIALOG_MODE_WITH_CANCEL
    param.textBoxMode     = sce.IME_DIALOG_TEXTBOX_MODE_PASSWORD if .Password in options else sce.IME_DIALOG_TEXTBOX_MODE_DEFAULT
    param.title           = raw_data(ime_title[:])
    param.maxTextLength   = u32(limit)
    param.initialText     = raw_data(ime_initial[:])
    param.inputTextBuffer = raw_data(ime_buffer[:])

    dialog_last_error = sce.sceImeDialogInit(&param)
    if dialog_last_error < 0 do return false
    dialog_kind = .Text_Input
    return true
}

// Call every frame while the keyboard is open. done is true on the one frame
// it has finished. If the user confirmed, accepted is true and text is the
// result as UTF-8, written into buf (a slice of it is returned; text that
// does not fit is cut off). Each character needs up to 3 bytes.
text_input_poll :: proc(buf: []u8) -> (text: string, accepted: bool, done: bool) {
    if dialog_kind != .Text_Input do return
    if sce.sceImeDialogGetStatus() != .FINISHED do return

    raw: sce.ImeDialogResult
    sce.sceImeDialogGetResult(&raw)
    sce.sceImeDialogTerm()
    dialog_kind = .None

    if u32(raw.button) != sce.IME_DIALOG_BUTTON_ENTER do return "", false, true

    length := 0
    for length < TEXT_INPUT_MAX_LENGTH && ime_buffer[length] != 0 do length += 1
    written := utf16.decode_to_utf8(buf, ime_buffer[:length])
    return string(buf[:written]), true, true
}

// ---------------------------------------------------------------
// Text conversion. The IME, save data titles and notifications use UTF-16.
// ---------------------------------------------------------------

// Writes s into dst as zero-terminated UTF-16, cutting it off if it does not
// fit. Returns the number of units written, not counting the terminator.
to_utf16 :: proc(dst: []u16, s: string) -> int {
    if len(dst) == 0 do return 0
    n := utf16.encode_string(dst[:len(dst) - 1], s)
    dst[n] = 0
    return n
}

// Converts zero-terminated UTF-16 to UTF-8 in buf and returns it as a string.
from_utf16 :: proc(buf: []u8, src: []u16) -> string {
    length := 0
    for length < len(src) && src[length] != 0 do length += 1
    return string(buf[:utf16.decode_to_utf8(buf, src[:length])])
}

@(private = "file")
open_message :: proc "contextless" (param: ^sce.MsgDialogParam) -> bool {
    dialog_last_error = sce.sceMsgDialogInit(param)
    if dialog_last_error < 0 do return false
    dialog_kind = .Message
    return true
}

// Copies s into dst with a terminating zero, cutting it off if it is too long.
@(private = "file")
copy_cstring :: proc "contextless" (dst: []u8, s: string) {
    n := min(len(s), len(dst) - 1)
    copy(dst[:n], s[:n])
    dst[n] = 0
}
