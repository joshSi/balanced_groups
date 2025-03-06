#ifndef GROUPMANAGER_H
#define GROUPMANAGER_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Error Struct
typedef struct {
  int error_code;
  char* error_message;
} Error;

//Group Struct
typedef struct {
  int num_members;
  char** members;
} Group;

// GroupManager Struct
typedef struct {
    int num_members;
    char** members;
    int num_groups;
    char**** group_history;
} GroupManager;

// Function Prototypes
Error* add_member(GroupManager* gs, char* member);
Error* remove_member(GroupManager* gs, char* member);
Error* create_groups(GroupManager* gs, char*** group_list);
Error* create_and_validate_groups(GroupManager* gs, char*** group_list);
void print_history(GroupManager* gs);
void free_groups(GroupManager* gs);

#endif // GROUPMANAGER_H
