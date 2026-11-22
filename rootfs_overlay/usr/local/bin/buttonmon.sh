#!/bin/bash

event_num="0"
event_type="EV_KEY"
event_btn_a="BTN_SOUTH"
event_btn_b="BTN_EAST"
event_btn_x="BTN_NORTH"
event_btn_y="BTN_WEST"
event_btn_r1="BTN_TR"
event_btn_r2="BTN_TR2"
event_btn_l1="BTN_TL"
event_btn_l2="BTN_TL2"
event_btn_hk="KEY_FN"


function Test_Button_A(){
  evtest --query /dev/input/event$event_num $event_type $event_btn_a
}

function Test_Button_B(){
  evtest --query /dev/input/event$event_num $event_type $event_btn_b
}

function Test_Button_X(){
  evtest --query /dev/input/event$event_num $event_type $event_btn_x
}

function Test_Button_Y(){
  evtest --query /dev/input/event$event_num $event_type $event_btn_y
}

function Test_Button_HK(){
  evtest --query /dev/input/event$event_num $event_type $event_btn_hk
}

function Test_Button_R1(){
  evtest --query /dev/input/event$event_num $event_type $event_btn_r1
}

function Test_Button_R2(){
  evtest --query /dev/input/event$event_num $event_type $event_btn_r2
}

function Test_Button_L1(){
  evtest --query /dev/input/event$event_num $event_type $event_btn_l1
}

function Test_Button_L2(){
  evtest --query /dev/input/event$event_num $event_type $event_btn_l2
}
