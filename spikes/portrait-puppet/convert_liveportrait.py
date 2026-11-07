# Convert LivePortrait's per-frame modules to Core ML and report what converts.
import sys, time, traceback, yaml, torch, numpy as np, coremltools as ct
sys.path.insert(0, '.')
from src.utils.helper import load_model

cfg = yaml.safe_load(open('src/config/models.yaml'))
W = 'pretrained_weights/liveportrait/base_models/'
out = sys.argv[1]

def convert(name, model, inputs):
    t0 = time.time()
    try:
        traced = torch.jit.trace(model, tuple(x for _, x in inputs), strict=False)
        ml = ct.convert(traced, inputs=[ct.TensorType(name=n, shape=x.shape) for n, x in inputs],
                        convert_to='mlprogram', compute_precision=ct.precision.FLOAT16,
                        minimum_deployment_target=ct.target.macOS15)
        ml.save(f'{out}/{name}.mlpackage')
        print(f'{name}: converted in {time.time()-t0:.0f}s', flush=True)
    except Exception as e:
        print(f'{name}: FAILED: {type(e).__name__}: {str(e)[:400]}', flush=True); traceback.print_exc(limit=-6)

class Motion(torch.nn.Module):
    def __init__(s, m): super().__init__(); s.m = m
    def forward(s, x): d = s.m(x); return d['kp'], d['exp'], d['pitch'], d['yaw'], d['roll'], d['t'], d['scale']
class Warp(torch.nn.Module):
    def __init__(s, m): super().__init__(); s.m = m
    def forward(s, f, kd, ks): return s.m(f, kd, ks)['out']

which = sys.argv[2:] or ['motion', 'generator', 'warping']
if 'motion' in which:
    convert('motion_extractor', Motion(load_model(W+'motion_extractor.pth', cfg, 'cpu', 'motion_extractor')), [('image', torch.rand(1, 3, 256, 256))])
if 'generator' in which:
    convert('spade_generator', load_model(W+'spade_generator.pth', cfg, 'cpu', 'spade_generator'), [('feature', torch.rand(1, 256, 64, 64))])
if 'warping' in which:
    convert('warping_module', Warp(load_model(W+'warping_module.pth', cfg, 'cpu', 'warping_module')),
            [('feature_3d', torch.rand(1, 32, 16, 64, 64)), ('kp_driving', torch.rand(1, 21, 3)), ('kp_source', torch.rand(1, 21, 3))])
