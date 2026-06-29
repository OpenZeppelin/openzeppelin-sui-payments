// Ambient module so `import "package/file.css"` side-effect imports type-check
// even when the package's exports field doesn't declare types for the CSS.
declare module "*.css";
