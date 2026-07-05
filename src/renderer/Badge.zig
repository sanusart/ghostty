const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const Image = @import("image.zig").Image;

pub const Badge = struct {
    pixels: ?[]u8 = null,
    width: u32 = 0,
    height: u32 = 0,

    pub fn render(
        alloc: Allocator,
        text: []const u8,
        font_name: []const u8,
        font_size: f64,
        r: u8,
        g: u8,
        b: u8,
        opacity: f64,
        glow: bool,
        glow_radius: f64,
        glow_r: u8,
        glow_g: u8,
        glow_b: u8,
    ) !Badge {
        if (text.len == 0) return Badge{};
        return switch (builtin.os.tag) {
            .macos => renderMacOS(alloc, text, font_name, font_size, r, g, b, opacity, glow, glow_radius, glow_r, glow_g, glow_b),
            else => Badge{},
        };
    }

    pub fn pendingImage(self: *const Badge) ?Image.Pending {
        const pixels = self.pixels orelse return null;
        if (self.width == 0 or self.height == 0) return null;
        return .{
            .width = self.width,
            .height = self.height,
            .pixel_format = .rgba,
            .data = @ptrCast(pixels.ptr),
        };
    }

    pub fn deinit(self: *Badge, alloc: Allocator) void {
        if (self.pixels) |p| alloc.free(p);
    }

    fn renderMacOS(
        alloc: Allocator,
        text: []const u8,
        font_name: []const u8,
        font_size: f64,
        r: u8,
        g: u8,
        b: u8,
        opacity: f64,
        glow: bool,
        glow_radius: f64,
        glow_r: u8,
        glow_g: u8,
        glow_b: u8,
    ) !Badge {
        const macos = @import("macos");

        const cf_str = try macos.foundation.String.createWithBytes(text, .utf8, false);
        defer cf_str.release();

        const font_name_cf = try macos.foundation.String.createWithBytes(font_name, .utf8, false);
        defer font_name_cf.release();

        const font_desc = try macos.text.FontDescriptor.createWithNameAndSize(font_name_cf, @floatCast(font_size));
        defer font_desc.release();

        const font = try macos.text.Font.createWithFontDescriptor(font_desc, @floatCast(font_size));
        defer font.release();

        const attr_str = try macos.foundation.MutableAttributedString.create(cf_str.getLength());
        defer attr_str.release();
        attr_str.replaceString(.{ .location = 0, .length = 0 }, cf_str);
        attr_str.setAttribute(
            .{ .location = 0, .length = @as(c_long, @intCast(cf_str.getLength())) },
            macos.text.StringAttribute.font,
            font,
        );
        attr_str.setAttribute(
            .{ .location = 0, .length = @as(c_long, @intCast(cf_str.getLength())) },
            macos.text.StringAttribute.foreground_color_from_context,
            @ptrCast(@constCast(macos.c.kCFBooleanTrue)),
        );

        const line = try macos.text.Line.createWithAttributedString(@ptrCast(attr_str));
        defer line.release();

        var ascent: f64 = 0;
        var descent: f64 = 0;
        var leading: f64 = 0;
        const typo_width = line.getTypographicBounds(&ascent, &descent, &leading);

        if (typo_width <= 0) return Badge{};

        const total_height = ascent + descent + leading;
        const pad: u32 = if (glow) @as(u32, @intFromFloat(@ceil(glow_radius))) else 0;
        const bmp_w: u32 = @as(u32, @intFromFloat(@ceil(typo_width))) + 2 * pad;
        const bmp_h: u32 = @as(u32, @intFromFloat(@ceil(total_height))) + 2 * pad;
        if (bmp_w == 0 or bmp_h == 0) return Badge{};

        const bpr = bmp_w * 4;
        const buf = try alloc.alloc(u8, bmp_h * bpr);
        @memset(buf, 0);

        const cs = try macos.graphics.ColorSpace.createDeviceRGB();
        defer cs.release();

        const ctx = try macos.graphics.BitmapContext.create(
            buf,
            bmp_w,
            bmp_h,
            8,
            bpr,
            cs,
            @intFromEnum(macos.graphics.ImageAlphaInfo.premultiplied_last) |
                @intFromEnum(macos.graphics.BitmapInfo.byte_order_32_big),
        );
        defer macos.graphics.BitmapContext.context.release(ctx);

        const ctx_ops = macos.graphics.BitmapContext.context;
        ctx_ops.setShouldAntialias(ctx, true);
        ctx_ops.setShouldSmoothFonts(ctx, true);
        ctx_ops.setTextDrawingMode(ctx, .fill);
        ctx_ops.setRGBFillColor(
            ctx,
            @as(f64, @floatFromInt(r)) / 255.0,
            @as(f64, @floatFromInt(g)) / 255.0,
            @as(f64, @floatFromInt(b)) / 255.0,
            opacity,
        );
        ctx_ops.setTextPosition(ctx, @floatFromInt(pad), @floatCast(descent + @as(f64, @floatFromInt(pad))));

        if (glow) {
            const glow_components = [_]f64{
                @as(f64, @floatFromInt(glow_r)) / 255.0,
                @as(f64, @floatFromInt(glow_g)) / 255.0,
                @as(f64, @floatFromInt(glow_b)) / 255.0,
                opacity,
            };
            const glow_color = macos.c.CGColorCreate(
                @ptrCast(cs),
                &glow_components,
            );
            if (glow_color) |gc| {
                macos.c.CGContextSetShadowWithColor(
                    @ptrCast(ctx),
                    @bitCast(macos.graphics.Size{ .width = 0, .height = 0 }),
                    glow_radius,
                    gc,
                );
                macos.c.CGColorRelease(gc);
            }
        }

        macos.c.CTLineDraw(@ptrCast(line), @ptrCast(ctx));

        // Convert premultiplied alpha to non-premultiplied
        for (0..bmp_h) |row| {
            for (0..bmp_w) |col| {
                const off = row * bpr + col * 4;
                const a = buf[off + 3];
                if (a > 0 and a < 255) {
                    buf[off + 0] = @min(@as(u16, buf[off + 0]) * 255 / a, 255);
                    buf[off + 1] = @min(@as(u16, buf[off + 1]) * 255 / a, 255);
                    buf[off + 2] = @min(@as(u16, buf[off + 2]) * 255 / a, 255);
                }
            }
        }

        return Badge{
            .pixels = buf,
            .width = bmp_w,
            .height = bmp_h,
        };
    }
};
