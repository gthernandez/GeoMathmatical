"""capture/ -- one module per object domain (plan 2.4).

Design rule (plan 2.4): capture is PURE READ. Each domain module returns raw REST
objects for its family; no normalization or sanitization happens here.

For v0 the actual reads are data-driven by endpoints.py and executed generically
by tree_walker.walk(), so these domain modules are thin: they exist as the seam
where family-specific read logic (special params, child fan-out, per-model quirks)
lands as it outgrows the generic walker. identity.py is the first to gain real
logic (the D25 ladder is already in ../array_models.py).
"""
