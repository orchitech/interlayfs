# interlayfs

interlayfs is a tool for composing a Linux filesystem tree from several other
trees. It is a variation on union filesystems like aufs and overlay. The key
difference is that interlayfs does not provide filesystem layers shadowing
the lower layers. Instead, it combines several filesystem trees in a way
that the resulting virtual fs tree routes all I/O to the original trees
according to the configuration. interlayfs is a mount-like tool for managing
complex Linux bind-mount setup in an user-frientdly way. interlayfs is not
actually not a filesystem.

## Usage

```
 interlayfs [-ri] [-o options] --treefile file --pathfile dir
 interlayfs -u dir
```

TBD.

## Typical Use Case

Mass virtual hosting of interpreted applications. As an example consider a
project with
- Vendor scripts
- Customization scripts
- Application data relevant to a single node in a cluster environment - usually temporary or cache files
- Application data shared across nodes - usually persistent user data

TBD.

## Contributing

TBD.

# Bugs and TODO

- Make up a recursive acronym "interlayfs ... not ... filesystem" :-)
- Implement usage without a root tree?
- Better atomic mounting and umounting using `mount --move`
- Make environment variable substitutions work more contextually rather than like just "macro preprocessing"
- Add more unit tests
- Add more docs and a man page
