# YADIF Output Texture Reuse Design

## Goal

Reduce CPU work and frame-presentation jitter on interlaced playback without changing YADIF output pixels, cadence, buffering, or failure behavior.

## Scope

This first optimization batch has two deliverables:

1. Measure CPU time spent encoding a YADIF command and preparing a Metal render submission.
2. Reuse the Metal plane mappings already created for each YADIF output instead of mapping the same output pixel buffer again in `MetalVideoRenderer`.

Input-reference mapping reuse, shader tiling, display-link threading, compressed-payload copy removal, and audio decoder scheduling remain later work. Their value will be reconsidered from the new measurements.

## Architecture

`YADIFNV12Kernel.encode` already maps five pixel buffers: three inputs and two outputs. It will continue to own every mapping until its command buffer completes. The encoded-resource token will expose presentation-safe `MetalPlaneSet` values for the two output mappings. Each plane set retains its output `CVPixelBuffer`, the two `CVMetalTexture` wrappers, and the mapper/cache owner required by the mapped textures.

`YADIFCommandSubmitting` will return optional output plane sets with a successful command result. The system submitter returns them; existing fake or alternate submitters may return `nil`. `YADIFProcessor` uses `.metalPlanes` when mappings are present and preserves `.pixelBuffer` as the compatibility fallback. This keeps the optimization isolated from scheduling and makes failures behave exactly as before.

The renderer already supports `.metalPlanes`, so it needs no new texture-lifetime policy. Its normal command-completion lifetime retains the plane set until GPU rendering finishes.

## Data Flow

1. The processor allocates two progressive output pixel buffers.
2. The kernel maps input and output planes once and encodes YADIF.
3. The system submitter retains all mappings until YADIF GPU completion.
4. On success, the submitter passes two `MetalPlaneSet` values to the processor.
5. The processor creates two presentation frames backed by `.metalPlanes`.
6. The renderer submits those textures directly and retains their backing objects through render completion.

When output mappings are unavailable, step 5 emits `.pixelBuffer` frames and the renderer performs its existing mapping path.

## Measurement

`PlaybackMetricsSnapshot` gains windowed p95 values for:

- YADIF CPU encode time: command-buffer creation, texture mapping, encoder setup, and commit preparation, excluding GPU execution.
- Render CPU preparation time: presentation selection through texture acquisition and render-job construction, excluding GPU completion.

Both recorders reject negative and non-finite samples and use the existing 120-second bounded retention window. The acceptance JSON obtains the fields through `Codable` without adding UI polling.

## Correctness and Lifetime Invariants

- Output pixels, timestamps, sequence numbers, field order, and two-fields-per-source cadence are unchanged.
- Input mappings are released before invoking user completion, as today.
- Output textures retain their pixel buffer and CoreVideo wrappers until the renderer's Metal command completes.
- Reset or stale-generation completion still returns no frames.
- Failed YADIF commands never publish output mappings.
- Fake submitters remain able to exercise the pixel-buffer fallback.

## Testing

Tests will be added before production changes and must demonstrate:

- Metrics compute the two p95 values and exclude expired samples.
- A successful command carrying output mappings produces `.metalPlanes` frames with correct textures and retained objects.
- A success without mappings still produces `.pixelBuffer` frames.
- Stale and failed commands do not publish mapped output frames.
- Existing YADIF golden-pixel, async-lifetime, renderer, playback-metrics, and integration tests remain green.

Verification then builds the Release app for the paired `指定测试` Apple TV and runs the existing long-play acceptance path. The optimized run is compared with the latest known baseline using presentations per second, missed display-link vsyncs, GPU p95, the two new CPU p95 values, drops, AV drift, and audio stalls. A regression in output correctness, sustained presentation cadence, or stalls blocks adoption.
