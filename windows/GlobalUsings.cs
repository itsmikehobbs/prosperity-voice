// WPF (enabled only for UI Automation) drops System.IO from the implicit usings because its own
// Path shape type clashes with System.IO.Path.
global using System.IO;
global using Path = System.IO.Path;
