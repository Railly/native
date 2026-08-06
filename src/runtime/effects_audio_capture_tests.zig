//! Audio-capture coverage: `fx.audioCapture` and `fx.stopAudioCapture`
//! through the fake executor (deterministic request/feed round trips,
//! rejection) and the real executor against the null platform's fake
//! recorder — the same `PlatformServices` seam the AppKit host's
//! AVAudioEngine tap and ScreenCaptureKit stream serve on macOS. One
//! capture at a time, key-identified events, explicit failure reasons,
//! and honest automation-snapshot state.
//!
//! The load-bearing invariant these tests pin: PCM never crosses the
//! effects channel. The platform writes both WAV files itself, so what
//! travels here is two paths in and levels/totals back.

const std = @import("std");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const platform = @import("../platform/root.zig");

const canvas_label = "capture-canvas";

const capture_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const capture_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Capture",
    .width = 400,
    .height = 300,
    .views = &capture_views,
}};
const capture_scene: app_manifest.ShellConfig = .{ .windows = &capture_windows };

const CaptureModel = struct {
    event_count: usize = 0,
    last_kind: ?effects_mod.EffectAudioCaptureEventKind = null,
    last_key: u64 = 0,
    last_mic_level: u8 = 0,
    last_system_level: u8 = 0,
    last_bytes_written: u64 = 0,
    last_duration_ms: u64 = 0,
    last_reason: effects_mod.EffectAudioCaptureFailureReason = .unsupported,
    started_count: usize = 0,
    level_count: usize = 0,
    stopped_count: usize = 0,
    failed_count: usize = 0,
    rejected_count: usize = 0,

    fn record(model: *CaptureModel, event: effects_mod.EffectAudioCapture) void {
        model.event_count += 1;
        model.last_kind = event.kind;
        model.last_key = event.key;
        model.last_mic_level = event.mic_level;
        model.last_system_level = event.system_level;
        model.last_bytes_written = event.bytes_written;
        model.last_duration_ms = event.duration_ms;
        model.last_reason = event.reason;
        switch (event.kind) {
            .started => model.started_count += 1,
            .level => model.level_count += 1,
            .stopped => model.stopped_count += 1,
            .failed => model.failed_count += 1,
            .rejected => model.rejected_count += 1,
        }
    }
};

const CaptureMsg = union(enum) {
    start,
    start_empty_mic,
    start_same_paths,
    stop,
    stop_other_key,
    capture_event: effects_mod.EffectAudioCapture,
};

const CaptureApp = ui_app_model.UiApp(CaptureModel, CaptureMsg);
const CaptureEffects = CaptureApp.Effects;

const session_key: u64 = 77;
const other_key: u64 = 78;
const mic_path = "/tmp/twintape/session-01/mic.wav";
const system_path = "/tmp/twintape/session-01/system.wav";

fn captureUpdate(model: *CaptureModel, msg: CaptureMsg, fx: *CaptureEffects) void {
    switch (msg) {
        .start => fx.audioCapture(.{
            .key = session_key,
            .mic_path = mic_path,
            .system_path = system_path,
            .on_event = CaptureEffects.audioCaptureMsg(.capture_event),
        }),
        .start_empty_mic => fx.audioCapture(.{
            .key = session_key,
            .mic_path = "",
            .system_path = system_path,
            .on_event = CaptureEffects.audioCaptureMsg(.capture_event),
        }),
        // Two tracks cannot share one file.
        .start_same_paths => fx.audioCapture(.{
            .key = session_key,
            .mic_path = mic_path,
            .system_path = mic_path,
            .on_event = CaptureEffects.audioCaptureMsg(.capture_event),
        }),
        .stop => fx.stopAudioCapture(session_key),
        .stop_other_key => fx.stopAudioCapture(other_key),
        .capture_event => |event| model.record(event),
    }
}

fn captureView(ui: *CaptureApp.Ui, model: *const CaptureModel) CaptureApp.Ui.Node {
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} events", .{model.event_count})),
        ui.button(.{ .on_press = .start }, "Start"),
        ui.button(.{ .on_press = .stop }, "Stop"),
    });
}

const Harness = struct {
    harness: *core.TestHarness(),
    app_state: *CaptureApp,
    app: core.App,

    const Config = struct {
        /// false models a host without a recorder (Windows and Linux
        /// today): both service fns are nulled BEFORE the platform value
        /// is captured, the same shape those hosts really wire.
        audio_capture: bool = true,
        /// false models the user declining Microphone or Screen
        /// Recording: the start is accepted and the capture then fails
        /// asynchronously with `.permission_denied`.
        audio_capture_permitted: bool = true,
    };

    fn create() !Harness {
        return createConfigured(.{});
    }

    fn createConfigured(config: Config) !Harness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.audio_capture = config.audio_capture;
        harness.null_platform.audio_capture_permitted = config.audio_capture_permitted;
        // The harness snapshots the services at create; re-capture so
        // the toggle above nulls the service fns the runtime hands the
        // effects channel — the wiring a real recorder-less host ships.
        harness.runtime.options.platform = harness.null_platform.platform();
        const app_state = try std.testing.allocator.create(CaptureApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = CaptureApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-audio-capture",
            .scene = capture_scene,
            .canvas_label = canvas_label,
            .update_fx = captureUpdate,
            .view = captureView,
        });
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(400, 300),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        try std.testing.expect(app_state.installed);
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
    }
};

// ------------------------------------------------------------ fake executor

test "fake executor records the capture request and feeds events back as msgs" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    // Start: the request is recorded whole, not executed — nothing
    // touches the platform recorder.
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    const request = fx.audioCaptureRequest().?;
    try std.testing.expectEqual(session_key, request.key);
    try std.testing.expectEqualStrings(mic_path, request.mic_path);
    try std.testing.expectEqualStrings(system_path, request.system_path);
    try std.testing.expectEqual(@as(usize, 0), h.harness.null_platform.audio_capture_start_count);

    // The started acknowledgment: both tracks are really running.
    try fx.feedAudioCaptureEvent(.{ .key = session_key, .kind = .started });
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.started_count);
    try std.testing.expectEqual(session_key, h.app_state.model.last_key);
    try std.testing.expect(fx.audioCaptureSnapshot().started);

    // Level ticks move the meter mirrors. Levels, never samples.
    try fx.feedAudioCaptureEvent(.{
        .key = session_key,
        .kind = .level,
        .mic_level = 180,
        .system_level = 42,
    });
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(effects_mod.EffectAudioCaptureEventKind.level, h.app_state.model.last_kind.?);
    try std.testing.expectEqual(@as(u8, 180), h.app_state.model.last_mic_level);
    try std.testing.expectEqual(@as(u8, 42), h.app_state.model.last_system_level);
    try std.testing.expectEqual(@as(u8, 180), fx.audioCaptureSnapshot().mic_level);
    try std.testing.expectEqual(@as(u64, 1), fx.audioCaptureSnapshot().level_events);

    // The one stop carries the host's honest totals and releases the
    // channel — nothing is left to record.
    try fx.feedAudioCaptureEvent(.{
        .key = session_key,
        .kind = .stopped,
        .bytes_written = 5_760_000,
        .duration_ms = 30_000,
    });
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.stopped_count);
    try std.testing.expectEqual(@as(u64, 5_760_000), h.app_state.model.last_bytes_written);
    try std.testing.expectEqual(@as(u64, 30_000), h.app_state.model.last_duration_ms);
    try std.testing.expect(!fx.audioCaptureSnapshot().active);
    try std.testing.expect(fx.audioCaptureRequest() == null);
}

test "an empty path is rejected before the platform is asked" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    try h.app_state.dispatch(&h.harness.runtime, 1, .start_empty_mic);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.rejected_count);
    try std.testing.expectEqual(session_key, h.app_state.model.last_key);
    // Rejected means the channel never occupied — no recorder to stop.
    try std.testing.expect(fx.audioCaptureRequest() == null);
    try std.testing.expect(!fx.audioCaptureSnapshot().active);
}

test "two tracks cannot share one file" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    try h.app_state.dispatch(&h.harness.runtime, 1, .start_same_paths);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.rejected_count);
    try std.testing.expect(!fx.audioCaptureSnapshot().active);
}

test "a start while one capture runs is rejected, never a silent replace" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try fx.feedAudioCaptureEvent(.{ .key = session_key, .kind = .started });
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.started_count);

    // The running capture owns two open files; replacing it silently
    // would lose the recording in flight.
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.rejected_count);
    // The original capture is untouched.
    try std.testing.expect(fx.audioCaptureSnapshot().started);
    try std.testing.expectEqual(session_key, fx.audioCaptureRequest().?.key);
}

test "stopping a key that names no capture is a harmless no-op" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    // Nothing running at all.
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.event_count);

    // A capture running under a DIFFERENT key: the caller may be racing
    // a failure that already tore its own capture down.
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try fx.feedAudioCaptureEvent(.{ .key = session_key, .kind = .started });
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop_other_key);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expect(fx.audioCaptureSnapshot().started);
}

test "an event for a stale key is swallowed, never misattributed" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try fx.feedAudioCaptureEvent(.{ .key = other_key, .kind = .level, .mic_level = 99 });
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.level_count);
    try std.testing.expectEqual(@as(u8, 0), fx.audioCaptureSnapshot().mic_level);
}

// --------------------------------------------------- real executor / platform

test "the real executor drives the null platform recorder end to end" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    const null_platform = &h.harness.null_platform;

    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try std.testing.expectEqual(@as(usize, 1), null_platform.audio_capture_start_count);
    // The paths reached the platform verbatim — the whole ABI contract:
    // the host writes the files, so the paths are all it needs.
    try std.testing.expectEqualStrings(mic_path, null_platform.audio_capture_state.micPath());
    try std.testing.expectEqualStrings(system_path, null_platform.audio_capture_state.systemPath());

    // The started acknowledgment a live host delivers once both tracks
    // run, routed through the platform event path.
    const started = null_platform.takeAudioCaptureStarted().?;
    try h.harness.runtime.dispatchPlatformEvent(h.app, started);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.started_count);
    try std.testing.expect(fx.audioCaptureSnapshot().started);

    // Meters tick while capturing.
    const level = null_platform.advanceAudioCapture(100).?;
    try h.harness.runtime.dispatchPlatformEvent(h.app, level);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.level_count);

    // Stop: the platform flushes both files and reports its totals.
    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try std.testing.expectEqual(@as(usize, 1), null_platform.audio_capture_stop_count);
    const stopped = null_platform.takeAudioCaptureStopped().?;
    try h.harness.runtime.dispatchPlatformEvent(h.app, stopped);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.stopped_count);
    // 100ms of two mono 48 kHz 16-bit tracks.
    try std.testing.expectEqual(@as(u64, 100), h.app_state.model.last_duration_ms);
    try std.testing.expectEqual(@as(u64, 19_200), h.app_state.model.last_bytes_written);
    try std.testing.expect(!fx.audioCaptureSnapshot().active);
}

test "a denied TCC grant fails the capture instead of crashing or going silent" {
    var h = try Harness.createConfigured(.{ .audio_capture_permitted = false });
    defer h.destroy();
    const fx = &h.app_state.effects;
    const null_platform = &h.harness.null_platform;

    // The start is ACCEPTED — a real host cannot know synchronously
    // whether TCC will grant, so the refusal is asynchronous.
    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try std.testing.expectEqual(@as(usize, 1), null_platform.audio_capture_start_count);

    const failed = null_platform.takeAudioCaptureStarted().?;
    try h.harness.runtime.dispatchPlatformEvent(h.app, failed);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.failed_count);
    try std.testing.expectEqual(
        effects_mod.EffectAudioCaptureFailureReason.permission_denied,
        h.app_state.model.last_reason,
    );
    // Nothing was recorded, so the channel is idle: the app can retry
    // after sending the user to System Settings.
    try std.testing.expect(!fx.audioCaptureSnapshot().active);
    try std.testing.expect(!fx.audioCaptureSnapshot().started);
}

test "a host without a recorder reports unsupported instead of half-recording" {
    var h = try Harness.createConfigured(.{ .audio_capture = false });
    defer h.destroy();
    const fx = &h.app_state.effects;

    // The feature report is honest before anything is attempted.
    try std.testing.expect(!h.harness.runtime.supports(.audio_capture));

    try h.app_state.dispatch(&h.harness.runtime, 1, .start);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.failed_count);
    try std.testing.expectEqual(
        effects_mod.EffectAudioCaptureFailureReason.unsupported,
        h.app_state.model.last_reason,
    );
    try std.testing.expect(!fx.audioCaptureSnapshot().active);
}

test "a recorder-capable host reports the feature supported" {
    var h = try Harness.create();
    defer h.destroy();
    try std.testing.expect(h.harness.runtime.supports(.audio_capture));
}
