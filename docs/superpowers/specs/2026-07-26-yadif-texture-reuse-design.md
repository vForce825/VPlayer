# YADIF GPU Tiling and Output Texture Reuse Design

## Goal

Reduce CPU work and frame-presentation jitter on interlaced playback without changing YADIF output pixels, cadence, buffering, or failure behavior.

## Scope

This optimization batch has three deliverables:

1. Measure CPU time spent encoding a YADIF command and preparing a Metal render submission.
2. Stage each YADIF spatial-search row window in threadgroup memory so neighboring threads do not repeatedly fetch the same texels.
3. Reuse the Metal plane mappings already created for each YADIF output instead of mapping the same output pixel buffer again in `MetalVideoRenderer`.

Input-reference mapping reuse, display-link threading, compressed-payload copy removal, and audio decoder scheduling remain later work. Their value will be reconsidered from the new measurements.

## Baseline Evidence

Two consecutive 60-second runs on the paired `指定测试` Apple TV 4K (3rd generation), using `五星体育 HD`, produced 49.28/49.22 presentations per second and 24.97/24.95 decoder callbacks per second. Decode is keeping up, but YADIF GPU p95 was 39.75/40.12 ms, superseded drops were 64/79, and missed display-link vsyncs were 81/90. The stable GPU result makes shader memory traffic the first optimization target; output mapping reuse alone cannot lower this GPU interval.

## Approaches Considered

### Threadgroup spatial-window tiling — selected

Each output pixel currently loads seven samples from the row above and seven from the row below even though adjacent pixels' windows overlap by six samples. For a 32-pixel-wide tile, this is roughly 448 spatial texture reads per row pair. Loading two shared rows with a three-pixel halo takes roughly 76 reads, an approximately 83% reduction for that part of the kernel. The arithmetic and output values remain unchanged.

### Fuse both output fields into one dispatch — deferred

This halves dispatch count, but the two synthesized fields use opposite row parity and therefore different spatial windows. Most expensive reads and arithmetic cannot be shared. It also increases register pressure and binds two writable outputs per kernel, so it is less attractive before tiling is measured.

### Reuse output mappings only — retained as a secondary change

This removes redundant CoreVideo-to-Metal mapping and allocations on the display-link path. It is low risk and useful for CPU jitter, but it does not address the measured 40 ms GPU p95.

## Architecture

### GPU spatial-window tiling

The four public Metal entry points remain unchanged. Each entry point receives one dynamically sized threadgroup-memory block matching its scalar (`int`) or chroma-vector (`int2`) code type. The Swift encoder uses the pipeline execution width for the tile width and caps tile height at eight row pairs, also respecting `maxTotalThreadsPerThreadgroup` and the device/pipeline threadgroup-memory limit.

For each local row-pair coordinate, every thread loads the center sample from the current frame's row above and below. The first three threads additionally load the left and right halo samples, using the existing clamped-coordinate sampling helper. After a threadgroup barrier, every thread reconstructs the same seven-element `FieldWindow` from shared memory and runs the existing spatial and temporal arithmetic unchanged.

Partial tiles and image edges deliberately use the same coordinate clamping as the current implementation. Both copied and synthesized output rows, NV12 and P010, top-field-first and bottom-field-first, and spatial-only mode preserve bit-exact golden output.

The tile height is capped rather than filling `maxTotalThreadsPerThreadgroup`: the kernel has meaningful register pressure, and smaller two-dimensional groups allow more resident groups while keeping shared-memory use bounded. The initial cap of eight is a measured implementation choice and may only be changed by a subsequent device A/B result.

### Output texture reuse

`YADIFNV12Kernel.encode` already maps five pixel buffers: three inputs and two outputs. It will continue to own every mapping until its command buffer completes. The encoded-resource token will expose presentation-safe `MetalPlaneSet` values for the two output mappings. Each plane set retains its output `CVPixelBuffer`, the two `CVMetalTexture` wrappers, and the mapper/cache owner required by the mapped textures.

`YADIFCommandSubmitting` will return optional output plane sets with a successful command result. The system submitter returns them; existing fake or alternate submitters may return `nil`. `YADIFProcessor` uses `.metalPlanes` when mappings are present and preserves `.pixelBuffer` as the compatibility fallback. This keeps the optimization isolated from scheduling and makes failures behave exactly as before.

The renderer already supports `.metalPlanes`, so it needs no new texture-lifetime policy. Its normal command-completion lifetime retains the plane set until GPU rendering finishes.

## Data Flow

1. The processor allocates two progressive output pixel buffers.
2. The kernel maps input and output planes once, stages overlapping spatial input samples per threadgroup, and encodes YADIF.
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
- NV12 and P010 golden outputs remain byte-for-byte identical across field orders and motion fixtures.
- Threadgroup tiling changes only where spatial input codes are stored between texture read and arithmetic; it does not change sampling coordinates or equations.
- Input mappings are released before invoking user completion, as today.
- Output textures retain their pixel buffer and CoreVideo wrappers until the renderer's Metal command completes.
- Reset or stale-generation completion still returns no frames.
- Failed YADIF commands never publish output mappings.
- Fake submitters remain able to exercise the pixel-buffer fallback.

## Testing

Tests will be added before production changes and must demonstrate:

- Metrics compute the two p95 values and exclude expired samples.
- Kernel encoding reserves the expected bounded threadgroup-memory size for scalar and vector planes.
- The production shader contains a threadgroup barrier and keeps every existing entry point.
- A successful command carrying output mappings produces `.metalPlanes` frames with correct textures and retained objects.
- A success without mappings still produces `.pixelBuffer` frames.
- Stale and failed commands do not publish mapped output frames.
- Existing YADIF golden-pixel, async-lifetime, renderer, playback-metrics, and integration tests remain green.

Verification then builds the app for the paired `指定测试` Apple TV and runs two consecutive 60-second acceptance passes under the same Debug configuration as the two recorded baselines. Release is also built to catch configuration-specific compiler issues. The optimized runs are compared using presentations per second, missed display-link vsyncs, GPU p95, the two new CPU p95 values, drops, AV drift, and audio stalls. A regression in output correctness, sustained presentation cadence, or stalls blocks adoption. The batch is accepted only if both optimized runs improve YADIF GPU p95 from the 39.75–40.12 ms baseline and do not worsen presentations per second or audio recovery count.
