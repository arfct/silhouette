# Does Core ML convert LivePortrait's 3D (5-D tensor) grid_sample, and the 2D one?
import torch, torch.nn.functional as F, coremltools as ct, sys
out = sys.argv[1]
class G3(torch.nn.Module):
    def forward(s, x, g): return F.grid_sample(x, g, align_corners=False)
for name, x, g in [('grid3d', torch.rand(1, 32, 16, 64, 64), torch.rand(1, 16, 64, 64, 3) * 2 - 1),
                   ('grid2d', torch.rand(1, 512, 64, 64), torch.rand(1, 64, 64, 2) * 2 - 1)]:
    try:
        t = torch.jit.trace(G3(), (x, g))
        m = ct.convert(t, inputs=[ct.TensorType(name='x', shape=x.shape), ct.TensorType(name='g', shape=g.shape)],
                       convert_to='mlprogram', compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS15)
        m.save(f'{out}/{name}.mlpackage'); print(name, 'converted')
    except Exception as e:
        print(name, 'FAILED:', type(e).__name__, str(e)[:300])
