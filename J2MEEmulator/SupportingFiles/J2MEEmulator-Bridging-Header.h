#ifndef J2MEEmulator_Bridging_Header_h
#define J2MEEmulator_Bridging_Header_h

#include "NativeBridge/jvm_bridge.h"
#include "NativeBridge/j2me_render.h"
#include "NativeBridge/j2me_input.h"
#include "NativeBridge/j2me_ui.h"
#include "NativeBridge/j2me_audio.h"

// Getters for Form/List/Alert data built by j2me_ui.m
const char *j2me_ui_get_form_title(void);
int j2me_ui_get_form_item_count(void);
int j2me_ui_get_form_item_type(int index);
const char *j2me_ui_get_form_item_label(int index);
const char *j2me_ui_get_form_item_text(int index);
int j2me_ui_get_form_item_param2(int index);
int j2me_ui_get_form_item_param1(int index);
int j2me_ui_get_command_count(void);
const char *j2me_ui_get_command_label(int index);
int j2me_ui_get_command_type(int index);
int j2me_ui_get_command_id(int index);
int j2me_ui_get_list_item_count(void);
const char *j2me_ui_get_list_item(int index);
int j2me_ui_get_list_type(void);
const char *j2me_ui_get_alert_text(void);
int j2me_ui_get_alert_timeout(void);

#endif /* J2MEEmulator_Bridging_Header_h */
