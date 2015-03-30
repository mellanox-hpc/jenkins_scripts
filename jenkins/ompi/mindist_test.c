#include "mpi.h"

#define _GNU_SOURCE
#include <sched.h>
#include <numa.h>

#include <errno.h>
#include <unistd.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int command_calc(const char *string)
{
#define COMMAND_CALC_BFF_SIZE 1024

	char *result, buffer[COMMAND_CALC_BFF_SIZE];

	FILE *command = popen(string, "r");

	if (NULL == command) {
		return -1;
	}

	result = fgets(buffer, sizeof(buffer), command);
	pclose(command);

	if (NULL == result) {
		return -1;
	}

    return atoi(result);
}

int get_cores_number(void)
{
    int cores_number;

	cores_number = command_calc("cat /proc/cpuinfo | grep \"physical id\" | sort | uniq | wc -l");
	cores_number *= command_calc("grep \"core id\" /proc/cpuinfo | sort | uniq | wc -l");

    return cores_number;
}

int get_closed_numa(char *hca)
{
    int cnuma;
    char *cmd;
    asprintf(&cmd, "cat /sys/class/infiniband/%s/device/numa_node", hca);
    cnuma = command_calc(cmd);
    free(cmd);
    return cnuma;
}

int get_numa_cores_number(void)
{
    int cores_number;

	cores_number = command_calc("grep \"core id\" /proc/cpuinfo | sort | uniq | wc -l");

    return cores_number;
}

int main(int argc, char* argv[])
{
    char *dist_hca = NULL, *policy = NULL, *policy_copy = NULL, *pch;
    cpu_set_t cpuset;

    int i, rc, my_rank,
	    numcpus, size;
    int numa = -1, next, numa_node;

    numcpus = get_cores_number();
	if (numcpus < 0) {
		fprintf(stderr, "\nBad CPUs number.\n");
		fflush(stderr);
		return 0;
	}
    
    rc = MPI_Init(&argc, &argv);
    if (MPI_SUCCESS != rc) {
        printf ("\nError starting MPI program. Terminating.\n");
        MPI_Abort(MPI_COMM_WORLD, rc);
    }

    MPI_Comm_rank(MPI_COMM_WORLD, &my_rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    
    if (size > get_numa_cores_number()) {
		fprintf(stderr, "\nrank - %d: number of processes exceeds number of cores at a single numa node. Test won't get correct results in this case.\n", my_rank);
		fflush(stderr);
        MPI_Finalize();
        return 0;
    }

    policy = getenv("OMPI_MCA_rmaps_base_mapping_policy");
    if (NULL != policy) {
        policy_copy = strdup(policy);
        dist_hca = strstr(policy_copy, "dist:");
        dist_hca += strlen("dist:");
        if (NULL != (pch = strchr(dist_hca, ','))) {
            *pch = '\0';
        }
    }

    if (NULL == dist_hca) {
		fprintf(stderr, "\nrank - %d: the \"dist\" mapping policy was not specified.\n", my_rank);
		fflush(stderr);
        MPI_Finalize();
        if (NULL != policy_copy) {
            free(policy_copy);
        }
		return 0;
	}
    
    numa_node = get_closed_numa(dist_hca);
    if (-1 == numa_node) {
        fprintf(stderr, "\nrank - %d: info about locality to %s isn't provided by the BIOS.\n", my_rank, dist_hca);
        fflush(stderr);
        MPI_Finalize();
        if (NULL != policy_copy) {
            free(policy_copy);
        }
		return 0;
    }
    if (NULL != policy_copy) {
        free(policy_copy);
    }
    
    CPU_ZERO(&cpuset);
    if (sched_getaffinity(0, sizeof(cpuset), &cpuset) < 0) {
		fprintf(stderr, "\nrank - %d: sched_getaffinity failed, errno says %s\n", my_rank, strerror(errno));
		fflush(stderr);
        MPI_Finalize();
		return -1;
	}

    for (i = 0; i < numcpus; ++i) {
	    if (CPU_ISSET(i, &cpuset)) {
            next = numa_node_of_cpu(i);
            if (-1 != numa && next != numa) {
                fprintf(stderr, "\nError rank - %d: scheduled on more than one numa node\n", my_rank);
                fflush(stderr);
                MPI_Finalize();
                return 1;
            }
            numa = next;
	    }
    }

    if (numa_node != numa) {
        fprintf(stderr, "\nError rank - %d: scheduled on wrong NUMA node - %d, should be %d\n", my_rank, numa, numa_node);
        fflush(stderr);
        MPI_Finalize();
		return 1;
    }

    fprintf(stderr, "\nSuccess rank - %d: only one NUMA is scheduled\n", my_rank);
    fflush(stderr);

    MPI_Finalize();

    return 0;
}
