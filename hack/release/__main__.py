"""Run with python3 -m release from hack/, or via release.sh."""
import argparse
import sys

from .artifacts import Registry, write_resources
from .integrity import inspect
from .manifest import BUNDLE, candidates, load, ref
from .prepare import prepare


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('validate', 'check'):
        commands.add_parser(name).add_argument('manifest')
    commands.add_parser('prepare').add_argument('output')
    extract = commands.add_parser('extract')
    extract.add_argument('manifest')
    extract.add_argument('output')
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare(args.output)
        return
    manifest = load(args.manifest)
    if args.command == 'check':
        inspect(manifest)
    elif args.command == 'extract':
        write_resources(Registry().resources(ref(candidates(manifest)[BUNDLE])), args.output)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(1)
