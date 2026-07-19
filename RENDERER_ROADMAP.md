# Keywork renderer roadmap

## North star

Every client buffer takes the cheapest correct path, every GPU-shareable buffer
is imported without copies, color is transformed exactly once, blending is
correct, and presentation has minimum latency. Keywork can explain every
fallback.

The renderer follows four rules:

1. Measure before optimizing. A fast path is not complete until its use and
   rejection reasons are observable.
2. Preserve color and alpha correctness across every path. Direct scanout and
   overlay planes must agree with composition.
3. Avoid CPU copies and GPU round trips when a supported DMA-BUF path exists.
4. Keep quality deterministic. Performance shortcuts must not silently change
   the rendered result.

## Foundation

Keywork already has:

- Vulkan composition with DMA-BUF format-modifier import and export.
- Explicit synchronization with DRM sync objects and sync files.
- Direct scanout, partial damage, retained output images, and backdrop caching.
- FP16 linear-light composition, blending, and blur.
- Parametric Wayland color management for sRGB, Display P3, BT.2020, PQ, HLG,
  BT.1886, and custom gamma transfer functions.
- HDR-to-SDR tone mapping, output encoding, and dithering.
- EDID-derived output descriptions and color-aware direct-scanout decisions.

The native KMS path is currently limited to 8-bit SDR scanout. The internal
pipeline can process HDR content, but it cannot yet drive a display in an HDR
mode.

## 1. Rendering observability — in progress

- [x] Report rolling GPU total, composition/effects, and output-encode timings
  per output through `keyworkctl stats`.
- [ ] Count CPU uploads and imported DMA-BUFs.
- [x] Report direct-scanout rejection reasons, including renderer eligibility
  and KMS presentation failures.
- [ ] Record the working format, scanout format, output transform, damage, and
  active render path for diagnostic captures.

Acceptance: every presented frame is attributable to direct scanout or
composition; every composition fallback has a reason; and a repeatable capture
can compare p50, p95, p99, and worst-case frame costs before and after a change.

## 2. 10-bit KMS and true HDR output

- Allocate and prefer 10-bit scanout buffers where the plane supports them.
- Own connector colorspace, HDR output metadata, maximum-bpc, and KMS color
  state as one atomic output configuration.
- Select SDR or HDR output mode from display capability and rendered content,
  with a predictable SDR fallback.

Acceptance: HDR test patterns reach a capable display through a 10-bit path
with the intended primaries, transfer function, luminance metadata, and no
8-bit truncation; unsupported displays remain color-correct SDR.

## 3. Perceptual tone mapping and gamut mapping

- Replace channel-wise clipping with hue-preserving luminance tone mapping.
- Add perceptual gamut compression for wide-gamut content on narrower outputs.
- Keep source and output reference luminance explicit throughout the pipeline.

Acceptance: reference ramps remain monotonic, neutral colors remain neutral,
out-of-gamut colors approach the target boundary without hard channel clips,
and HDR highlights retain detail under SDR conversion.

## 4. ICC profiles and calibration

- Load per-output ICC profiles and calibration data.
- Compile profile transforms into renderer-owned GPU resources.
- Invalidate retained images and scanout eligibility when calibration changes.

Acceptance: matrix/TRC and LUT-based reference profiles match the conformance
corpus within its published tolerance, and profile changes take effect without
mixing old and new color state in one frame.

## 5. Native video buffers

- Import and sample multi-planar NV12 and P010 DMA-BUFs without CPU conversion.
- Apply explicit YCbCr matrix, range, chroma siting, and transfer metadata.
- Preserve P010 precision through HDR composition and scanout.

Acceptance: supported video buffers incur no CPU upload, limited/full range and
chroma siting are correct, and P010 remains greater than 8-bit through the
render path.

## 6. High-quality fractional scaling

- Select filters by transform: exact nearest-neighbor for pixel-aligned content
  and a high-quality reconstruction filter for fractional scaling.
- Reduce repeated resampling when surface and output transforms can be folded
  into one operation.

Acceptance: the scaling corpus has no half-pixel instability or unintended
blur at integer scales, fractional-scale quality beats bilinear reconstruction,
and the quality path stays inside the target frame budget.

## 7. Color-aware DRM overlay planes

- Promote eligible surfaces to overlay planes without changing their color,
  alpha, transform, synchronization, or presentation semantics.
- Include plane assignment and rejection reasons in renderer diagnostics.

Acceptance: video and opaque surfaces use overlays when the complete atomic
state is supported, composition remains the reliable fallback, and switching
between paths does not produce a visible color or timing discontinuity.

## 8. Conformance and benchmark suite

- Build reference image tests for transfer functions, primaries, blending,
  tone mapping, gamut mapping, scaling, and YCbCr conversion.
- Add reproducible scenes for direct scanout, mixed windows, damage, blur,
  video, SDR, and HDR.
- Track CPU time, GPU pass time, memory bandwidth proxies, copies, imports,
  missed frame budgets, and presentation latency.

Acceptance: renderer changes can be evaluated with one documented command,
produce machine-readable results, and fail CI on correctness regressions while
retaining historical performance data for hardware runs.
