# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

import sys
import os
import random
import subprocess
import time
import argparse

def get_run_status(filepath_of_log_file):
    """
    Checks if the string "Execution completed" exists in the log file.
    If it does, returns the full line containing that string.
    Otherwise, returns "ERROR".
    """
    try:
        with open(filepath_of_log_file, 'r') as log_file:
            for line in log_file:
                if "Execution completed" in line:
                    return line.strip()
        return "ERROR"
    except Exception as e:
        return f"ERROR: {e}"


def check_simFail(filepath):
    try:
        with open(filepath, "rb") as f:
            return b"simFail" in f.read()
    except FileNotFoundError:
        return False

def run_command_with_random_seeds(command, num_runs, num_heartbeats, max_run_parallel):
    processes = []
    launched_runs = 0

    while processes or launched_runs < num_runs:
        # Launch new processes if we have capacity
        while len(processes) < max_run_parallel and launched_runs < num_runs:
            seed = random.randint(1, 1000000)
            env = os.environ.copy()
            env['LOTUS_VL_RAND_SEED'] = str(seed)
            env['LOTUS_SIM_HEARTBEATS'] = str(num_heartbeats)
            log_filename = f"log_{seed}.txt"
            log_file = open(log_filename, 'w')
            start_time = time.time()
            process = subprocess.Popen(command, shell=True, stdout=log_file, stderr=subprocess.STDOUT, env=env)
            processes.append({
                'process': process,
                'seed': seed,
                'log_file': log_file,
                'log_filename': log_filename,
                'start_time': start_time
            })
            launched_runs += 1

        # Monitor the processes
        for p in processes[:]:
            retcode = p['process'].poll()
            if retcode is not None:  # Process finished
                p['log_file'].close()
                # Compute elapsed time in minutes
                end_time = time.time()
                elapsed_time = (end_time - p['start_time']) / 60
                # Get run status
                status = get_run_status(p['log_filename'])
                # Remove the process from the list
                processes.remove(p)
                # Calculate runs remaining
                runs_remaining = (num_runs - launched_runs) + len(processes)
                # Print the seed, status, time taken, and runs remaining
                simFail = check_simFail(p["log_filename"])
                print(f"Seed: {p['seed']}, Status: {status}, simFail: {simFail} -- Time Taken: {elapsed_time:.2f} minutes, Runs Remaining: {runs_remaining}")
                if not simFail and ("deadlocked=0" in status):
                    try:
                        os.remove(p['log_filename'])
                        print(f"    Deleted: {p['log_filename']}")
                    except OSError as e:
                        print(f"Error deleting {p['log_filename']}: {e}")
                if simFail or ("deadlocked=1" in status):
                    print(f"    Finished Execution")
                    # Kill all other processes
                    for o in processes:
                        o['process'].kill()
                        o['log_file'].close()
                        if o["log_filename"] != p["log_filename"]:
                            try:
                                os.remove(o['log_filename'])
                                print(f"       Deleted to finish: {o['log_filename']}")
                            except OSError as e:
                                print(f"Error deleting {o['log_filename']}: {e}")
                    exit(0)
        time.sleep(0.1)

# Example usage
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Run command with random seeds.')
    parser.add_argument('command', help='The command to run.')
    parser.add_argument('--num-heartbeats', type=int, default=50, help='Number of heartbeats')
    parser.add_argument('--num-runs', type=int, default=250, help='Number of runs')
    parser.add_argument('--max-run-parallel', type=int, default=250, help='Maximum number of runs to execute in parallel')

    args = parser.parse_args()

    command = args.command
    num_heartbeats = args.num_heartbeats
    num_runs = args.num_runs
    max_run_parallel = args.max_run_parallel

    print(f"Command: {command}")
    run_command_with_random_seeds(command, num_runs, num_heartbeats, max_run_parallel)

