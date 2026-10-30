"""Run with python3 -m release from hack/, or via release.sh."""
import argparse
import sys

from .artifacts import Registry, write_resources
from .integrity import inspect
from .manifest import BUNDLE, candidates, load, ref
from .prepare import prepare
from .config import materialize, catalog_changelog
from .publish import publish
from .acceptance import acceptance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('validate', 'check'):
        commands.add_parser(name).add_argument('manifest')
    commands.add_parser('prepare').add_argument('output')
    extract = commands.add_parser('extract')
    extract.add_argument('manifest')
    extract.add_argument('output')
    config = commands.add_parser('config')
    config.add_argument('manifest')
    config.add_argument('output')
    commands.add_parser('catalog-changelog').add_argument('manifest')
    publication = commands.add_parser('publish')
    for arg in ('manifest', 'evidence', 'catalog', 'result'):
        publication.add_argument(arg)
    tests = commands.add_parser('acceptance')
    tests.add_argument('manifest')
    tests.add_argument('output')
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare(args.output)
        return
    manifest = load(args.manifest)
    if args.command == 'check':
        inspect(manifest)
    elif args.command == 'extract':
        write_resources(Registry().resources(ref(candidates(manifest)[BUNDLE])), args.output)
    elif args.command == 'config':
        materialize(manifest, args.output)
    elif args.command == 'catalog-changelog':
        catalog_changelog(manifest)
    elif args.command == 'publish':
        publish(manifest, args.manifest, args.evidence, args.catalog, args.result)
    elif args.command == 'acceptance':
        acceptance(manifest, args.manifest, args.output)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(1)
