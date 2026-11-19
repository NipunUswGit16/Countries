# Kairos Frontend - React
This is a Frontend interface for kairos apps, built on React and Typescript. This builds the web frontend to access kairos application. Often communicates through the REST APIs, built in Client API. This contents are always placed inside the kairos application under "web" directory (see the root `AGENTS.md`).

## Directory Structure
```
src/
└── public/                     # Public resources such as helix-icons, images and other 3rd party scripts.
└── config/                     # Application-level configuration files & routes.
└── features/                   # Feature modules - self-contained units of business functionality.
└── lib/                        # Reusable library packages that need a clear boundary from the rest of the application code.
└── pages/                      # Top-level page components that are mapped to routes
└── styles/                     # Global styles that apply across the entire application
```

## Development Guide
Refer the *.md files given below and follow the provided instructions during the development.
- Application level configs & Routes - Refer `./config/README.md`
- Developing business functionality or features - Refer `./features/README.md`
- Implement reusable libraries or utilities - Refer `./libs/README.md`
- Build route page components - Refer `pages/README.md`
- Global styling and reusable CSS tokens or classes - Refer `styles/README.md`
