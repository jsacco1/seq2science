import re
import genomepy
import subprocess
import pandas as pd
from multiprocessing.pool import ThreadPool
from snakemake.utils import validate


# read the samples file
samples = pd.read_csv(config["samples"], sep='\t')
validate(samples, schema=f"../schemas/{schema}")
samples = samples.set_index('sample')
samples.index = samples.index.map(str)


# TODO: maybe move to other locations? Cleaner?
# apply workflow specific changes
if 'condition' in samples:
    samples['condition'] = samples['condition'].str.replace(" ","")

if 'assembly' in samples:
    config['assemblies'] = set(samples['assembly'])

if 'peak_caller' in config:
    config['peak_caller'] = {k: v for d in config['peak_caller'] for k, v in d.items()}
    assert all(key in ['macs2', 'genrich'] for key in config['peak_caller'].keys())

# cut off trailing slashes
for path in ['result_dir', 'genome_dir', 'log_dir']:
    config[path] = re.split("\/$", config[path])[0]

# check if paired-end filename suffixes are lexicograpically ordered
config['fqext'] = [config['fqext1'], config['fqext2']]
assert sorted(config['fqext'])[0] == config['fqext1']


# check if a sample is single-end or paired end, and store it
results = []
tp = ThreadPool(1)  # TODO: get key for more requests! https://ncbiinsights.ncbi.nlm.nih.gov/2017/11/02/new-api-keys-for-the-e-utilities/

def get_layout(sample):
    return sample, subprocess.check_output(
        f'''esearch -db sra -query {sample} | efetch | grep -Po "(?<=<LIBRARY_LAYOUT><)[^/><]*"''',
        shell=True).decode('ascii').rstrip()

for sample in samples.index:
    results.append(tp.apply_async(get_layout, (sample,)))
config['layout'] = {r.get()[0]: r.get()[1] for r in results}

# Do onstart/onexit things
onstart:
    # turn off genomepy plugins, since they slow down the 'downloading' process
    if 'genomepy' in sys.modules:
        # get the genomepy settings
        config['active_plugins'] = [p.name() for p in genomepy.plugin.get_active_plugins()]

        # disable genomepy plugins
        for plugin in ['bowtie2', 'bwa', 'gmap', 'hisat2', 'minimap2']:
            genomepy.plugin.deactivate(plugin)


def onexit(config):
    if 'genomepy' in sys.modules:
        for plugin in genomepy.plugin.plugins:
            if plugin in config['active_plugins']:
                genomepy.plugin.activate(plugin)


onerror:
    onexit(config)


onsuccess:
    onexit(config)
