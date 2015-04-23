#include <stdio.h>
#include <stdlib.h>
#include <mpi.h>
int main(int argc, char **argv, char **env)
{
    int i=0;
    char *astr;
    MPI_Init(&argc,&argv);
    astr=env[i];
    while(astr) {
        printf("%s\n",astr);
        astr=env[++i];
    }
   MPI_Finalize();
}
