#!/bin/bash
# Shared settings for build.sh and test.sh.

APP_NAME=Mimo
BUNDLE_ID=com.brianzheng.mimo
MODULE_CACHE="${TMPDIR:-/private/tmp}/mimo-swift-module-cache"

# Every .swift in mac/, in the order build.sh links them.
APP_SOURCES=(
  panel_geometry.swift
  companion_geometry.swift
  companion_physics.swift
  companion_sprite.swift
  companion_window.swift
  companion_expression.swift
  companion_runtime.swift
  activity_log.swift
  app_menu.swift
  custom_pet.swift
  character_sheet.swift
  generation_draft.swift
  generation_ledger.swift
  style_reference.swift
  reference_preprocessor.swift
  main.swift
  product.swift
  pet_generation.swift
)

APP_FRAMEWORKS=(
  Cocoa WebKit Carbon Security ImageIO
  Vision CoreImage CoreVideo LocalAuthentication
)
