#include "group_manager.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

Error* add_member(GroupManager* gs, char* member) {
    if (gs == NULL || member == NULL) {
        Error* error = malloc(sizeof(Error));
        error->error_code = -1;
        error->error_message = "Invalid input";
        return error;
    }
    gs->members = realloc(gs->members, (gs->num_members + 1) * sizeof(char*));
    gs->members[gs->num_members - 1] = malloc(strlen(member) + 1);
    strcpy(gs->members[gs->num_members - 1], member);
    gs->num_members++;
    Error* error = malloc(sizeof(Error));
    error->error_code = 0;
    error->error_message = "Success";
    return error;
}

Error* remove_member(GroupManager* gs, char* member) {
    if (gs == NULL || member == NULL) {
        Error* error = malloc(sizeof(Error));
        error->error_code = -1;
        error->error_message = "Invalid input";
        return error;
    }
    int index = -1;
    for(int i = 0; i < gs->num_members; i++){
      if(strcmp(gs->members[i], member)==0){
        index = i;
        break;
      }
    }
    if(index == -1){
      Error* error = malloc(sizeof(Error));
      error->error_code = -2;
      error->error_message = "Member not found";
      return error;
    }
    
    for(int i = index; i < gs->num_members - 1; i++){
      gs->members[i] = gs->members[i+1];
    }
    gs->members = realloc(gs->members, (gs->num_members - 1) * sizeof(char*));
    gs->num_members--;
    Error* error = malloc(sizeof(Error));
    error->error_code = 0;
    error->error_message = "Success";
    return error;
}

Error* create_groups(GroupManager* gs, char*** group_list) {
  if (gs == NULL || group_list == NULL) {
        Error* error = malloc(sizeof(Error));
        error->error_code = -1;
        error->error_message = "Invalid input";
        return error;
  }
    gs->group_history = realloc(gs->group_history, (gs->num_groups + 1) * sizeof(char**));
    gs->group_history[gs->num_groups] = group_list;
    gs->num_groups++;
    Error* error = malloc(sizeof(Error));
    error->error_code = 0;
    error->error_message = "Success";
    return error;
}

Error* create_and_validate_groups(GroupManager* gs, char*** group_list) {
  if (gs == NULL || group_list == NULL) {
        Error* error = malloc(sizeof(Error));
        error->error_code = -1;
        error->error_message = "Invalid input";
        return error;
  }
    for (int i = 0; i < gs->num_members; i++) {
        for (int j = 0; j < 3; j++) {
            if (gs->members[i] != group_list[0][j]) {
                Error* error = malloc(sizeof(Error));
                error->error_code = -2;
                error->error_message = "Member not in list";
                return error;
            }
        }
    }

    gs->group_history = realloc(gs->group_history, (gs->num_groups + 1) * sizeof(char**));
    gs->group_history[gs->num_groups] = group_list;
    gs->num_groups++;
    Error* error = malloc(sizeof(Error));
    error->error_code = 0;
    error->error_message = "Success";
    return error;
}

void print_history(GroupManager* gs) {
    if (gs == NULL) {
        return;
    }
    for (int i = 0; i < gs->num_groups; i++) {
        printf("Group %d: ", i);
        for (int j = 0; j < 3; j++) {
            printf("%s ", gs->group_history[i][j]);
        }
        printf("\n");
    }
}

void free_groups(GroupManager* gs) {
  if(gs == NULL) return;
  for(int i = 0; i < gs->num_groups; i++){
    for(int j = 0; j < 3; j++){
        free(gs->group_history[i][j]);
    }
    free(gs->group_history[i]);
  }
}
