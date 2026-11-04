using System.Drawing.Drawing2D;

namespace ProsperityVoice;

static class Brand
{
    public static readonly Color Navy = Color.FromArgb(10, 25, 41);
    public static readonly Color LightNavy = Color.FromArgb(21, 44, 66);
    public static readonly Color Red = Color.FromArgb(230, 57, 70);
    public static readonly Color Yellow = Color.FromArgb(255, 214, 10);
    public static readonly Color Gray = Color.FromArgb(138, 148, 166);
}

/// <summary>Floating pill near the bottom of the screen. Never takes keyboard focus.</summary>
public sealed class RecordingPanel : Form
{
    enum Mode { Hidden, Recording, Working, Message }

    Mode mode = Mode.Hidden;
    string text = "";
    bool good = true;
    bool handsFree;
    DateTime startedAt;
    readonly float[] levels = new float[18];
    readonly System.Windows.Forms.Timer tick = new() { Interval = 100 };
    readonly System.Windows.Forms.Timer hideTimer = new();
    Rectangle cancelBox, finishBox;

    public event Action? FinishClicked;
    public event Action? CancelClicked;

    public RecordingPanel()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Size = new Size(480, 48);
        BackColor = Color.Magenta;
        TransparencyKey = Color.Magenta;
        DoubleBuffered = true;
        Font = new Font("Segoe UI", 10f, FontStyle.Bold);
        tick.Tick += (_, _) => Invalidate();
        hideTimer.Tick += (_, _) => { hideTimer.Stop(); HidePanel(); };
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000008;   // NOACTIVATE | TOOLWINDOW | TOPMOST
            return cp;
        }
    }

    public void ShowRecording(bool handsFree)
    {
        hideTimer.Stop();
        Array.Clear(levels);
        this.handsFree = handsFree;
        startedAt = DateTime.Now;
        mode = Mode.Recording;
        tick.Start();
        Present();
    }

    public void SetHandsFree() { handsFree = true; Invalidate(); }

    public void ShowWorking(string message)
    {
        hideTimer.Stop();
        mode = Mode.Working;
        text = message;
        tick.Start();
        Present();
    }

    public void Flash(string message, bool good = true, double seconds = 1.6)
    {
        mode = Mode.Message;
        text = message;
        this.good = good;
        tick.Stop();
        Present();
        hideTimer.Stop();
        hideTimer.Interval = (int)(seconds * 1000);
        hideTimer.Start();
    }

    public void HidePanel()
    {
        hideTimer.Stop();
        tick.Stop();
        mode = Mode.Hidden;
        Hide();
    }

    public void PushLevel(float level)
    {
        Array.Copy(levels, 1, levels, 0, levels.Length - 1);
        levels[^1] = level;
    }

    void Present()
    {
        var screen = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(screen.Left + (screen.Width - Width) / 2, screen.Bottom - Height - 36);
        if (!Visible) Show();
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

        var content = MeasureContentWidth(g);
        var pill = new Rectangle((Width - content) / 2, 4, content, Height - 8);
        using (var path = Rounded(pill, pill.Height / 2))
        {
            using var fill = new SolidBrush(Brand.Navy);
            using var border = new Pen(Brand.LightNavy, 1);
            g.FillPath(fill, path);
            g.DrawPath(border, path);
        }

        var x = pill.Left + 14;
        var mid = pill.Top + pill.Height / 2;
        switch (mode)
        {
            case Mode.Recording:
                using (var red = new SolidBrush(Brand.Red)) g.FillEllipse(red, x, mid - 5, 10, 10);
                x += 18;
                foreach (var level in levels)
                {
                    var h = 4 + (int)(level * 20);
                    using var bar = new SolidBrush(Color.FromArgb((int)(140 + level * 115), Brand.Yellow));
                    g.FillRectangle(bar, x, mid - h / 2, 3, h);
                    x += 6;
                }
                x += 6;
                var secs = (int)(DateTime.Now - startedAt).TotalSeconds;
                TextRenderer.DrawText(g, $"{secs / 60}:{secs % 60:00}", Font, new Point(x, mid - 9), Brand.Gray);
                x += 44;
                if (handsFree)
                {
                    using var small = new Font("Segoe UI", 8.5f, FontStyle.Bold);
                    TextRenderer.DrawText(g, "hands-free", small, new Point(x, mid - 8), Brand.Yellow);
                    x += 74;
                }
                cancelBox = new Rectangle(x, mid - 11, 22, 22);
                finishBox = new Rectangle(x + 28, mid - 11, 22, 22);
                using (var b = new SolidBrush(Brand.LightNavy)) g.FillEllipse(b, cancelBox);
                using (var b = new SolidBrush(Brand.Red)) g.FillEllipse(b, finishBox);
                TextRenderer.DrawText(g, "✕", Font, cancelBox, Brand.Gray, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                TextRenderer.DrawText(g, "✓", Font, finishBox, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                break;
            case Mode.Working:
                var angle = (int)(DateTime.Now.TimeOfDay.TotalMilliseconds / 3) % 360;
                using (var spin = new Pen(Brand.Yellow, 2.5f)) g.DrawArc(spin, x, mid - 7, 14, 14, angle, 270);
                TextRenderer.DrawText(g, text, Font, new Point(x + 22, mid - 9), Color.White);
                break;
            case Mode.Message:
                using (var dot = new SolidBrush(good ? Brand.Yellow : Brand.Red)) g.FillEllipse(dot, x, mid - 6, 12, 12);
                TextRenderer.DrawText(g, text, Font, new Point(x + 20, mid - 9), Color.White);
                break;
        }
    }

    int MeasureContentWidth(Graphics g) => mode switch
    {
        Mode.Recording => Math.Min(Width - 4, 14 + 18 + 18 * 6 + 6 + 44 + (handsFree ? 74 : 0) + 56 + 10),
        _ => Math.Min(Width - 4, 14 + 22 + TextRenderer.MeasureText(g, text, Font).Width + 18),
    };

    static GraphicsPath Rounded(Rectangle r, int radius)
    {
        var p = new GraphicsPath();
        var d = radius * 2;
        p.AddArc(r.Left, r.Top, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (mode != Mode.Recording) return;
        if (finishBox.Contains(e.Location)) FinishClicked?.Invoke();
        else if (cancelBox.Contains(e.Location)) CancelClicked?.Invoke();
    }
}
