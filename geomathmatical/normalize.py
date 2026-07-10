"""normalize.py -- REST -> capture conventions (plan section 6, D22/D31). STUB.

Milestone 5. GeoMathmatical captures REST values FAITHFULLY (D31); normalize only
canonicalizes what sanitization coherence + completeness require -- diorama does
the convention-stripping. Concretely (plan section 6 table):
  - capacity: keep BOTH byteFormatCapacity + blockCapacity as-is
  - serial: keep 12-digit storageDeviceId AND bare serialNumber, prefix NOT stripped
  - host-group name: prefer the FULL name from host_groups over the <=16 truncated
    copy inside ldev.ports[] (RC5)
  - virtualLdevId: preserve 65534/65535 verbatim (GAD reserved attrs)
  - WWN: normalize hex case only

Consumes the raw tree from tree_walker.walk(); returns a normalized tree of the
same shape. Pure transform, no I/O.
"""


def normalize(raw_tree, identity):
    """TODO(milestone 5): apply the section-6 rules. Skeleton passes through."""
    return raw_tree
