#!/bin/bash
# Shared settings for build.sh and test.sh.

APP_NAME=Mimo
BUNDLE_ID=com.brianzheng.mimo
MODULE_CACHE="${TMPDIR:-/private/tmp}/mimo-swift-module-cache"

# Every .swift in mac/, in the order build.sh links them.
APP_SOURCES=(
  panel_geometry.swift
  starter_action.swift
  starter_action_job.swift
  companion_geometry.swift
  companion_physics.swift
  companion_sprite.swift
  companion_window.swift
  companion_expression.swift
  companion_behavior.swift
  companion_director.swift
  companion_runtime.swift
  activity_log.swift
  app_menu.swift
  custom_pet.swift
  pet_library.swift
  action_generation_job.swift
  character_sheet.swift
  action_sheet.swift
  action_sheet_run.swift
  generation_draft.swift
  generation_ledger.swift
  pet_reference_import.swift
  style_reference.swift
  reference_preprocessor.swift
  settings_typography.swift
  diy_style_preset.swift
  reflection_core.swift
  notion_reflection.swift
  reflection_model.swift
  reflection_browser.swift
  main.swift
  product.swift
  consistency_metric.swift
  pet_provider.swift
  pet_generation.swift
)

APP_FRAMEWORKS=(
  Cocoa WebKit Carbon Security ImageIO
  Vision CoreImage CoreVideo LocalAuthentication
)
