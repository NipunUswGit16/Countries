# Main Makefile for Kairos Component Template
# This repository follows a "Zero-Scripts" architecture.
# Infrastructure is dynamically resolved from the kairos-component-common/toolkit module.

# Initialize the Kairos build toolkit
include .init.mk

# Component configuration
COMPONENT_NAME ?= countries

# Include component specific make targets here...
