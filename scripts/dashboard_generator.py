#!/usr/bin/env python3

# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

import subprocess
import json
import sys
import numpy as np

def create_dashboard(data, title):
    total_elements = max([len(v) for k, v in data.items()])
    x_labels = list(range(0, total_elements))
    html_template = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>{title}</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
</head>
<body>
    <h1>{title}</h1>
    <button onclick="addGraph()">Add Graph</button>
    <button onclick="removeGraph()">Remove Graph</button>
    <div id="graphsContainer"></div>

    <script type="text/javascript">
        document.addEventListener('DOMContentLoaded', function() {{
            const data = {json.dumps(data)};

            const graphsContainer = document.getElementById('graphsContainer');
            let graphCount = 0;

            window.addGraph = function() {{
                graphCount++;
                const graphDiv = document.createElement('div');
                graphDiv.className = 'graph';
                graphDiv.id = 'graph' + graphCount;

                const canvas = document.createElement('canvas');
                const checkboxesDiv = document.createElement('div');
                checkboxesDiv.className = 'checkboxes';

                Object.keys(data).forEach(function(key) {{
                    const wrapper = document.createElement('div');
                    const checkbox = document.createElement('input');
                    checkbox.type = 'checkbox';
                    checkbox.id = key + graphCount;
                    checkbox.value = key;
                    checkbox.onchange = function() {{ toggleDataset(graphCount, this); }};

                    const label = document.createElement('label');
                    label.htmlFor = key + graphCount;
                    label.textContent = key;

                    wrapper.appendChild(checkbox);
                    wrapper.appendChild(label);
                    checkboxesDiv.appendChild(wrapper);
                }});

                graphDiv.appendChild(checkboxesDiv);
                graphDiv.appendChild(canvas);
                graphsContainer.appendChild(graphDiv);

                const ctx = canvas.getContext('2d');
                new Chart(ctx, {{
                    type: 'line',
                    data: {{
                        labels: {x_labels},
                        datasets: []
                    }},
                }});
            }};

            window.removeGraph = function() {{
                if (graphCount > 0) {{
                    const graphToRemove = document.getElementById('graph' + graphCount);
                    graphsContainer.removeChild(graphToRemove);
                    graphCount--;
                }}
            }};

            function toggleDataset(graphNumber, checkbox) {{
                const graphDiv = document.getElementById('graph' + graphNumber);
                const chart = Chart.getChart(graphDiv.querySelector('canvas'));
                const labelKey = checkbox.value;
                const dataIndex = chart.data.datasets.findIndex(dataset => dataset.label === labelKey);
                if (checkbox.checked) {{
                    const newDataset = {{
                        label: labelKey,
                        data: data[labelKey],
                        borderColor: randomColor(),
                        tension: 0.1
                    }};
                    chart.data.datasets.push(newDataset);
                }} else {{
                    chart.data.datasets.splice(dataIndex, 1);
                }}
                chart.update();
            }};

            function randomColor() {{
                return 'rgb(' + [
                    Math.floor(Math.random() * 256),
                    Math.floor(Math.random() * 256),
                    Math.floor(Math.random() * 256)
                ].join(',') + ')';
            }}
        }});
    </script>
</body>
</html>"""

    return html_template

def find_lines_after_marker(file_path, marker):
    try:
        # Command to use grep to find the line number of the marker and print from there to the end of the file
        command = f"grep -A999999 '{marker}' {file_path} | tail -n +2"
        # Running the grep command
        result = subprocess.run(command, shell=True, text=True, capture_output=True, check=True)
        # Returning the output after the marker
        return result.stdout
    except subprocess.CalledProcessError as e:
        print(f"An error occurred: {e}")
        return None

def trim_arrays(data_dict):
    # Find the key that matches the specified pattern
    key_to_search = "chip*.Multile.tile*.core*.core-coreCounters.coreSimNumHbReg"
    if key_to_search not in data_dict:
        raise KeyError(f"Key '{key_to_search}' not found in the dictionary")

    # Get the array for the specified key
    target_array = data_dict[key_to_search]

    # Find the index of the first non-zero value
    non_zero_index = np.argmax(target_array != 0)

    # Trim the start of all np arrays
    for key in data_dict:
        data_dict[key] = data_dict[key][non_zero_index+1:]

    return data_dict

def normalize_dict_arrays(data_dict):
    for _, array in data_dict.items():
        if len(array) > 0:  # Ensure the array is not empty
            array -= array[0]
    return data_dict

def preprocess_data(data):
    data = {k: np.array(v) for k, v in data.items()}
    import re
    isVar = re.compile(r"^(.*)(\d+)$")
    def new_key(key):
        keys = key.split(".")

        keys = [(k, isVar.match(k)) for k in keys]
        key = ".".join([f"{m.group(1)}*" if m else k for (k, m) in keys ])
        return key

    new_data = {}
    for key in data.keys():
        new_k = new_key(key)
        if new_k not in new_data.keys():
            new_data[new_k] = data[key].copy()
        else:
            new_data[new_k] = new_data[new_k] + data[key]
        new_data[key] = data[key]

    new_data = trim_arrays(new_data)

    new_data = normalize_dict_arrays(new_data)

    data = {k: v.tolist() for k, v in new_data.items()}
    return data

def main():
    title = sys.argv[1]
    filename = sys.argv[2]
    #data = find_lines_after_marker(filename, "==PERF STATS START==")
    #data = json.loads(data)
    with open(filename) as f:
        data = json.load(f)
    data = preprocess_data(data)
    html = create_dashboard(data, title)

    print(html)

main()
