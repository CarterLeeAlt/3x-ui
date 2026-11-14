## Local Development Setup

- Create a directory named `x-ui` in the project root
- Rename `.env.example` to `.env `
- Run `main.go` with the Go version in `go.mod`.

The application uses the upstream `v2.9.4` baseline (`8bea0fde`), with Vue 2 and Ant Design Vue assets embedded from `web/assets` and server-rendered templates in `web/html`. The fork release version is `2.9.5`. Keep the existing page structure and controls.

The web language is fixed to Simplified Chinese. A fresh browser defaults to the light theme; only explicit theme controls change it, and local storage remembers the manual choice. System color changes do not change the panel theme.

Release packages use the official Xray `v26.3.27` binaries. The panel's Go library dependency includes certificate-binding security fixes independently of the packaged runtime. Windows management endpoints listen only on `127.0.0.1`.
