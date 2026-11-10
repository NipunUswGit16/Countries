# Library Directory

This directory is for reusable library packages that need a clear boundary from
the rest of the application code. This includes:

- **Internal libraries** - Code that is shared within the application but
  benefits from having its own separation and/or development cycle independent
  of the main application.
- **Publishable libraries** - Packages intended to be shared with other
  applications via a private or public package repository.

Code that is specific to a single feature belongs in `features/`, not here. Use
`lib/` when the code is general-purpose and could reasonably be used outside the
feature it originated from.

## AI Assistant Instructions

- **Do not place feature-specific code here** - If the code is only used by one
  feature, it belongs in that feature's folder.
- **Keep libraries self-contained** - Libraries should not depend on
  application-specific code like `features/`.
